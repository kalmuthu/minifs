#!/bin/bash

# prerequisites :
# libtool, bison, flex, genext2fs, squashfs, svn -- probably more
# u-boot-mkimage -- for the arm targets

#######################################################################
#
# (C) Michel Pollet <buserror@gmail.com>
#
#######################################################################
#
# this is the board we are making. Several boards can co-exist, the
# toolchains are "compatible" and live in the toolchain/ subdirectory.
# Several board of the same arch can also coexist, sharing the same
# toolchain
#
#######################################################################

set +o posix #needed for dashes in function names
set -m # enable job control

MINIFS_BOARD=${MINIFS_BOARD:-"atom"}

# get a default number of concurent jobs
MINIFS_JOBS=${MINIFS_JOBS:-$(cat /proc/cpuinfo |grep '^processor'|wc -l)}

MINIFS_BOARD_ROLE=${MINIFS_BOARD/*-}
MINIFS_BOARD_ROLE=${MINIFS_BOARD_ROLE//+/ }
# now remove the roles bits
MINIFS_BOARD=${MINIFS_BOARD/-*}

#######################################################################
# MINIFS_PATH contains collumn separated directories with extra
# package directories
# MINIFS_PACKAGES contains a list of space separated packaged to add
#
# if you want a .dot and .pdf file with all the .elf dependencies
# in your build folder, add this to your environment, you'll need
# GraphViz obviously
# export CROSS_LINKER_DEPS=1
#######################################################################

COMMAND=$1
COMMAND_PACKAGE=${COMMAND/_*}
COMMAND_TARGET=$2
COMMAND_TARGET=${COMMAND_TARGET:-${COMMAND/*_}}

echo MINIFS_BOARD $MINIFS_BOARD $COMMAND_TARGET $COMMAND_PACKAGE

#######################################################################
# bare minimum commands we need
# the packages themselves can add some, and they are all checked
# before anything is built to prevent wasting time and have the
# build fail in the middle
#######################################################################
NEEDED_HOST_COMMANDS="make tar rsync wget git"

BASE="$(pwd)"
export MINIFS_BASE="$BASE"

export BUILD="$BASE/build-${MINIFS_BOARD}"

CONF_BASE="$BASE/conf"
PATCHES="$CONF_BASE"/patches

export STAGING="$BUILD/staging"
export STAGING_USR="$STAGING/usr"
export TMPDIR="$BUILD/tmp"
export ROOTFS="$BUILD/rootfs"
export ROOTFS_PLUGINS=""
export ROOTFS_KEEPERS="libnss_dns.so.2:"
export STAGING_TOOLS="$BUILD"/staging-tools
KERNEL="$BUILD/kernel"

#######################################################################
# PACKAGES is the entire list of possible packages, as filled by the
# conf/packages/*.sh scripts, in their ideal build order.
# TARGET_PACKAGES are the ones requested by the target build script, in any
# order
# BUILD_PACKAGES is the same, but with alias resolved so "linux" becomes
# "linux-headers", "linux-modules" etc.
# The script for the union of these and can then have a list of packages
# to build.
#######################################################################
export PACKAGES=""

source "$CONF_BASE"/minifs-script-utils.sh

#######################################################################
# Look for the board/XXX location in either the extra configuration
# directory or the main conf/board/XXX one
#######################################################################
CONFIG=""
for pd in $(minifs_path_split "board/$MINIFS_BOARD") "$CONF_BASE/board/$MINIFS_BOARD"; do
	if [ -d "$pd" ]; then
		CONFIG="$pd"
	fi
done
if [ "$CONFIG" == "" ]; then
	echo Unable to find board $MINIFS_BOARD
	exit 1
fi

CONFIG_UCLIBC=$(grep '^CT_LIBC_uClibc' $(minifs_locate_config_path config_crosstools.conf))

# Extract the toolchain tupple and other bits from crosstools config
extra_env=$( cat $(minifs_locate_config_path config_crosstools.conf) | awk -e '
BEGIN { eabi="none"; os="none"; }
/^CT_ARCH_[a-z][^_]+=y/ { gsub(/[A-Z_]+|=y/, ""); arch=$0; print "TARGET_ARCH=" arch ";"; }
/^CT_TARGET_VENDOR=/ { gsub(/^[A-Z_=]+"?|"$/, ""); vendor="-" $0; print "TARGET_VENDOR=" $0 ";"; }
/^CT_KERNEL=/ { gsub(/^[A-Z_=]+"?|"$/, ""); os=$0; print "TARGET_OS=" os ";"; }
/^CT_ARCH_ARM_EABI=y/ { eabi="gnueabi"; }
/^CT_LIBC_uClibc=y/ { uclibc="uclibc"; print "CONFIG_UCLIBC=y;" }
END {
	printf "TARGET_FULL_ARCH=\"%s%s-%s-%s%s%s\";\n", arch,vendor,os,uclibc,eabi,hf;
}
' ; )
echo $extra_env
eval $extra_env

# this one is always mandatory
source "$CONFIG"/minifs-script*.sh

for script in $(minifs_locate_config_path "") ; do
	for try in "$TARGET_META_ARCH-minifs-script.sh" "$TARGET_ARCH-minifs-script.sh"; do
		if [ -f "$try" ]; then
			source $try
		fi
	done
done


# remove any package, and it's installed dirs
if [ "$COMMAND_TARGET" == "remove" ]; then
	remove_package $COMMAND_PACKAGE
	exit
fi

TOOLCHAIN="$BASE/toolchain"
TOOLCHAIN_BUILD="$BASE/build-toolchain"
CROSS_BASE="$TOOLCHAIN/$TARGET_FULL_ARCH/"
CROSS="$CROSS_BASE/bin/$TARGET_FULL_ARCH"
GCC="${CROSS}-gcc"

WGET="wget --no-check-certificate"
MAKE=make
MAKE_ARGUMENTS="-j$MINIFS_JOBS"

mkdir -p "$STAGING_TOOLS"/bin
mkdir -p download "$KERNEL" "$ROOTFS" "$STAGING_USR" "$TOOLCHAIN"
mkdir -p "$STAGING_USR"/share/aclocal $STAGING_TOOLS/share/aclocal
mkdir -p $TMPDIR/installwatch

# Always regenerate the rootfs
#rm -rf "$ROOTFS"/*

TARGET_INITRD=${TARGET_INITRD:-0}
TARGET_FS_SQUASH=${TARGET_FS_SQUASH:-0}
TARGET_FS_EXT=${TARGET_FS_EXT:-1}
# only set this if you /know/ the parameters for your NAND
# TARGET_FS_JFFS2="-q -l -p -e 0x20000 -s 0x800"

# use shared libraries ? overridable in the target's scripts
TARGET_SHARED=0

# compile the "tools" for the host
( 	set -x
	make -C "$CONF_BASE"/host-tools DESTDIR="$STAGING_TOOLS"
) >"$BUILD"/._tools.log 2>&1 || \
	( echo '## Unable to build tools :'; cat  "$BUILD"/._tools.log; exit 1 ) || exit 1
rm -f $TMPDIR/pkg-config.log
if [ "$COMMAND" == "tools" ]; then exit ;fi

# PATH needs sbin (for depmod), the host tools, and the cross toolchain
export BASE_PATH="$PATH"
export PATH="$TOOLCHAIN/bin:$TOOLCHAIN/$TARGET_FULL_ARCH/bin:$BUILD/staging-tools/bin:/usr/sbin:/sbin:$PATH"

# ccfix is the prefixer for gcc that warns of "absolute" host paths
export CC="ccfix $TARGET_FULL_ARCH-gcc"
export CXX="ccfix $TARGET_FULL_ARCH-g++"
export LD="ccfix $TARGET_FULL_ARCH-ld"

export TARGET_CPPFLAGS="-I$STAGING_USR/include"
export CPPFLAGS="$TARGET_CPPFLAGS"
export LDFLAGS_BASE="-L$STAGING_USR/lib"
export CFLAGS="$TARGET_CFLAGS"
export CXXFLAGS="$CFLAGS"
export LIBC_CFLAGS="${TARGET_LIBC_CFLAGS:-$TARGET_CFLAGS}"
export PKG_CONFIG_PATH="$STAGING/lib/pkgconfig:$STAGING_USR/lib/pkgconfig:$STAGING_USR/share/pkgconfig"
export PKG_CONFIG_LIBDIR="" # do not search local paths
export PKG_CONFIG=pkg-config
export ACLOCAL="aclocal -I $STAGING_USR/share/aclocal -I $STAGING_TOOLS/share/aclocal -I /usr/share/aclocal"
export HOST_INSTALL="/usr/bin/install"

KERNEL_CONFIG_FILE=$(minifs_locate_config_path config_kernel.conf)

# Look in this target's kernel config to know if we need/want modules
CONFIG_MODULES=$(grep '^CONFIG_MODULES=y' "$KERNEL_CONFIG_FILE")
CONFIG_KERNEL_LZO=$(grep '^CONFIG_KERNEL_LZO=y' "$KERNEL_CONFIG_FILE")

if [ "$CONFIG_KERNEL_LZO" != "" ]; then
	NEEDED_HOST_COMMANDS+=" lzop"
fi
# Modern crosstools needs all these too!
NEEDED_HOST_COMMANDS+=" curl svn cvs svn lzma"

export TARGET_PACKAGES="
	host-installwatch \
	host-automake \
	rootfs-create linux $NEED_CROSSTOOLS systemlibs busybox filesystems"
export BUILD_PACKAGES=""

# in minifs-script, optional
optional board_set_versions

#######################################################################
# if a local config file is found, run it, it allows quick
# testing of packages without changing the real board file etc
#######################################################################
for fil in .config .config-$(hostname -s) .config-$MINIFS_BOARD; do
	if [ -f "./$fil" ]; then
		source "./$fil"
	fi
done

#######################################################################
## Load all the package scripts and sort them by name
#######################################################################
#minifs_locate_config_path "packages" 3 ; exit
package_files=""
for pd in "$CONF_BASE/packages" $(minifs_path_split "packages") $(minifs_locate_config_path "packages" 1); do
	if [ -d "$pd" ]; then
		package_files+="$(echo $pd/*.sh) "
	fi
done

# filename_sort is in conf/host-tools
package_files=$(filename_sort $package_files)
# echo $package_files

#######################################################################
## Source all the package files in order.
## Attempts at setting them in 'groups' that is set via the
## XXfilename.sh numerical order
##
## This is not used for the moment
#######################################################################
fid=0
for p in $package_files; do
	name=$(basename $p)
	order=$(expr match "$name" '0*\([0-9]*\)')
#	echo $p $order
	filid=$(((order * 1000) + fid))
	fid=$((fid + 1))
#	package_set_group $filid
	source $p
done

# Add the list of external packages
TARGET_PACKAGES+=" $MINIFS_PACKAGES"
# filesystems id always the last one
TARGET_PACKAGES+=" filesystems"

optional board_prepare

# verify we have all the commands we need to build on the host
check_host_commands

#######################################################################
# if a local config file is found, run it, it allows quick
# testing of packages without changing the real board file etc
#######################################################################
for fil in .config .config-$(hostname -s) .config-$MINIFS_BOARD; do
	for dir in $(minifs_path_split "packages"); do
		if [ -f "$dir/$fil" ]; then
			source "$dir/$fil"
		fi
	done
done

if [ "$TARGET_SHARED" -eq 0 ]; then
	echo "### Static build!!"
	LDFLAGS_BASE="-static $LDFLAGS_BASE"
fi
export LDFLAGS_RLINK="$LDFLAGS_BASE -Wl,-rpath -Wl,/usr/lib -Wl,-rpath-link -Wl,$STAGING_USR/lib"
export LDFLAGS=$LDFLAGS_BASE

if [ "$COMMAND" == "depends" ]; then
	dump_depends
	exit
fi

#######################################################################
## Take all the selected packages, and add their dependencies
## This loops until none of the packages add any more.
#######################################################################
export TARGET_PACKAGES
while true; do
	changed=0; newlist=""
	for wpack in $TARGET_PACKAGES; do
		targets=$(hget $wpack targets)
		targets=${targets:-$wpack}
		for pack in $targets; do
			deps=$(hget $pack depends)
			for d in $deps; do
				if ! env_contains TARGET_PACKAGES $d; then
				#	echo ADD $pack depends on $d
					TARGET_PACKAGES+=" $d"; changed=1
				fi
			done
		done
	done
	if [ $changed -eq 0 ]; then break; fi
done

#######################################################################
## Give a chance to each package to cry for help, before downloading
#######################################################################
HOSTCHECK_FAILED=0
for package in $TARGET_PACKAGES; do
	PACKAGE=$package
	optional_one_of \
		$MINIFS_BOARD-hostcheck-$package \
		hostcheck-$package || break
	unset PACKAGE
done
if [ $HOSTCHECK_FAILED == 1 ]; then exit 1; fi
unset PACKAGE

compile-host-tools

#######################################################################
## Download the files, unpack, and patch them
#######################################################################
pushd download >/dev/null
# echo TARGET_PACKAGES $TARGET_PACKAGES
for package in $TARGET_PACKAGES; do
	fil=$(hget $package url)

	if [ "$fil" = "" ]; then continue ; fi

	# adds the list of targets provided by this package
	# to the list of the ones we want to build
	targets=$(hget $package targets)
	BUILD_PACKAGES+=" ${targets:-$package}"

	if [ "$fil" = "none" ]; then  continue ; fi

	proto=${fil/!*}
	fil=${fil/*!}
	base=${fil/*\//}
	typ=${fil/*.}
	url=${fil/\#*}
	loc=${base/*#/}
	vers=$(echo $base|sed -r 's|.*([-_](v?[0-9]+[a-z\-]*[\._]?)+)\..*|\1|')
	host=${url/*:\/\/}
	host=${host/\/*}
	gitref="$(hget $package git-ref)"

	# maybe the package has a magic downloader ?
	optional download-$package

	if [ ! -f "$loc" ]; then
		case "$proto" in
			# git repo URL are of format git!<url>#<filename to store>
			git)
				gitref=${gitref:-"master"}
				if [ ! -d "$package.git" ]; then
					echo "#### git clone $url $package.git"
					git clone "$url" "$package.git" &&
						git checkout $gitref
				fi
				if [ -d "$package.git" ]; then
					echo "#### Compressing $package to $loc"
					tar jcf "$loc" "$package.git" &&
						rm -rf "$package.git" &&
						rm -rf "$BUILD/$package"
				fi
			;;
			svn)	if [ ! -d "$package.svn" ]; then
					echo "#### svn clone $url $package.git"
					svnopt=$(hget $package svnopt)
					case "$svnopt" in
						none) svnopt=""; ;;
						*) svnopt="-s"; ;;
					esac
					set -x
					git svn clone $svnopt "$url" "$package.svn"
					set +x
				fi
				if [ -d "$package.svn" ]; then
					echo "#### Compressing $url"
					tar jcf "$loc" "$package.svn" &&
						rm -rf "$package.svn" &&
						rm -rf "$BUILD/$package"
				fi
			;;
			*) $WGET "$url" -O "$loc" || { rm -f "$loc"; exit 1; } ;;
		esac
	elif [ "$COMMAND_PACKAGE" = "download" ]; then
		echo -n Verifying $package URL
		case "$proto" in
			git|svn) echo " skipped ($proto)" ;;
			*) case "$host" in
					*.googlecode.com) echo " skipped (borken googlecode)" ;;
					*) if ! declare -F "download-$package" >/dev/null ; then
							$WGET \
								-q --spider --tries=5 "$url" || {
								echo; echo "ERROR: $url" ;
							#	exit 1;
							}
							echo " done"
						else
							echo " skipped (custom download)"
						fi
					;;
				esac
			;;
		esac
	elif [ "$COMMAND_PACKAGE" = "$package" -a "$COMMAND_TARGET" = "pull" ]; then
		case "$proto" in
			git)
				gitref=${gitref:-"master"}
				echo Trying to pull $package tree head $gitref
				rm -rf "$package.git"
				tar jxf "$loc" && (
					cd "$package.git"
					git pull &&
					git checkout $gitref
				) &&
				tar jcf "$loc" "$package.git" &&
				rm -rf "$package.git" &&
				remove_package $package &&
				echo $package tree updated, ready to rebuild
				;;
			*)
				echo "$package doesn't support 'pull'"
		esac
		exit 0
	fi
	baseroot=$package
	PACKAGE=$baseroot
	#echo $package = $fil
	# try to compare the URL to see if it changed, if so, remove
	# the old source and rebuild automagically
	if [ -f "$BUILD/$baseroot/._url" ]; then
		old=$(cat "$BUILD/$baseroot/._url")
		if [ "$fil" != "$old" ]; then
			echo "  ++  Rebuilding $baseroot "
			remove_package $baseroot
		fi
	fi
	# See if we want to keep the .git around, and if we have a
	# specific git tag/branch/commit to checkout
	excluder="--exclude=.git"
	if [ "$proto" == "git" ]; then
		if [ "$gitref" != "" ]; then
			excluder=""
		fi
	fi
	if [ ! -d "$BUILD/$baseroot" ]; then
		echo "####  Extracting $loc to $BUILD/$baseroot ($typ)"
		mkdir -p "$BUILD/$baseroot"
		echo "$fil" >"$BUILD/$baseroot/._url"
		echo "$vers" >"$BUILD/$baseroot/._version"
		case "$typ" in
			bz2)	tar jx $excluder -C "$BUILD/$baseroot" --strip 1 -f "$loc"	;;
			xz)		xzcat "$loc" | tar x $excluder -C "$BUILD/$baseroot" --strip 1	;;
			gz|tgz)	tar zx $excluder -C "$BUILD/$baseroot" --strip 1 -f "$loc"	;;
			tarb)	tar zx $excluder -C "$BUILD/$baseroot" -f "$loc" ;;
			run)	pushd "$BUILD/$baseroot"
				optional uncompress-$package "$BASE/download/$loc"
				popd
				;;
			*)	echo ### error file format '$typ' ($base) not supported" ; exit 1
		esac
		if [ "$gitref" != "" ]; then
			echo "****  $PACKAGE checking out $gitref"
			( cd "$BUILD/$baseroot"
				git checkout $gitref || exit 1
				git branch -b minifs-build
				true
			) >"$BUILD/$baseroot/.git_checkout" 2>&1 || \
				{ echo "$PACKAGE checkout $gitref ERROR, bailing"; exit 1; }
		fi
		( for pd in \
				"$PATCHES/$baseroot" "$PATCHES/$baseroot$vers" \
				$(minifs_path_split "patches/$baseroot") \
				$(minifs_path_split "patches/$baseroot$vers") \
				$(minifs_locate_config_path "$baseroot" 3) \
				$(minifs_locate_config_path "$baseroot$vers" 3) ; do
			echo trying patches $pd
			if [ -d "$pd" ]; then
				echo "#### Patching $base"
				pushd "$BUILD/$baseroot"
					for pf in "$pd/"/*.patch; do
						echo "     Applying $pf"
						cat $pf | patch --merge -t -p1
					done
				popd
			fi
		done
		pushd "$BUILD/$baseroot"
		echo Trying optional_one_of $MINIFS_BOARD-patch-$baseroot patch-$baseroot
		optional_one_of \
			$MINIFS_BOARD-patch-$baseroot \
			patch-$baseroot || break
		) >"$BUILD/$baseroot/._patch_$baseroot.log" 2>&1
	fi
done
unset PACKAGE
popd >/dev/null

if [ "$COMMAND" == "unpack" -o "$COMMAND" == "download" ]; then
	echo "$COMMAND done." ; exit;
fi

#######################################################################
## Default "build" phases Definitions -- for Autoconf targets
#######################################################################
configure-generic-local() {
	local ret=0 ; set -x
	local sysconf=$(hget $PACKAGE sysconf)
	sysconf=${sysconf:-/etc}
	if [ ! -f configure ]; then
		if [ -f autogen.sh ]; then
			./autogen.sh \
				--build=$(uname -m) \
				--host=$TARGET_FULL_ARCH \
				--prefix="$PACKAGE_PREFIX" \
				--sysconfdir=$sysconf
		elif [ -f configure.ac -o -f configure.in ]; then
			$ACLOCAL && libtoolize --copy --force --automake
			autoreconf --force #;libtoolize;automake --add-missing
		fi
	fi
	if [ -f configure ]; then
		./configure \
			--build=$(uname -m) \
			--host=$TARGET_FULL_ARCH \
			--prefix="$PACKAGE_PREFIX" \
			--sysconfdir=$sysconf \
			"$@" || ret=1
	else
		echo Nothing to configure
	fi
	set +x ;return $ret
}

configure-generic() {
	configure configure-generic-local "$@"
	set +x
}

compile-generic() {
	local extra=$(hget $PACKAGE compile)
	compile $MAKE $MAKE_ARGUMENTS $MAKE_CLEAN $extra "$@"
}

#######################################################################
## The install default handler tries to fix libtool stupidities
#######################################################################
install-generic-local() {
	local destdir=$(hget $PACKAGE destdir)
	local makei="installwatch -r $TMPDIR/installwatch -d $TMPDIR/installwatch/debug -o ._dist_$PACKAGE.log $MAKE install"
	set -x
	case "$destdir" in
		none) $makei "$@" ;;
		"") $makei DESTDIR="$STAGING" "$@" ;;
		*) $makei DESTDIR="$destdir" "$@" ;;
	esac
	lafiles=$(awk '{if ($2 == "open" && match($3,/.la$/)) print $3;}' ._dist_$PACKAGE.log)
	for n in $lafiles; do
		echo LDCONFIG PATCH $n
		sed -i -e "s|\([ ']\)/usr|\1$STAGING_USR|g" $n
	done
	# Check to see if there are lame comfig scripts around
	scr=$(hget $PACKAGE configscript)
	if [ "$scr" != "" ]; then
		for sc in "$STAGING_USR"/bin/$scr "$STAGING"/bin/$scr; do
			if [ -x "$sc" ]; then
				sed -e "s|=/usr|=$STAGING_USR|g" \
					-e "s|=\"/usr|=\"$STAGING_USR|g" "$sc" \
						>"$STAGING_TOOLS"/bin/$scr && \
					chmod +x "$STAGING_TOOLS"/bin/$scr
				break;
			fi
		done
	fi
	set +x
}

install-generic() {
	log_install install-generic-local "$@"
}
#######################################################################
# the default deploy phase does... nothing. Most packages are libraries
# and these are installed automaticaly in the target filesystem. The
# deploy phase is made only for the pakcages that want to install
# anything in the rootfs, like utils, etc, fonts etc etc
#######################################################################
deploy-generic() {
	return 0
}

#######################################################################
# shell handler allows dropping the user in an interactive shell
# when you call ./minifsbuild <package>_shell
#######################################################################
shell-generic() {
	echo "--- Entering interactive shell mode; type control D to exit"
	echo "    Environment is set so make & stuff should cross compile."
	echo "    This is BASH by the way, so you inherit the functions."
	echo "    " $(pwd)
	exec /bin/bash
}

#######################################################################
## Find out which package we want/have, and order them by build order
#######################################################################
DEPLIST=""
#echo PACKAGES $PACKAGES
# echo BUILD_PACKAGES $BUILD_PACKAGES
export BUILD_PACKAGES
for pack in $PACKAGES; do
	# check to see if that package was requested, otherwise, skip it
	dobuild=0
	if env_contains BUILD_PACKAGES $pack; then
		PROCESS_PACKAGES+=" $pack"
		DEPLIST+=" $pack($(hget $pack depends) $(hget $pack optional))"
	fi
done

#######################################################################
## Call the dependency sorter, and get back the result
#######################################################################
# echo DEPLIST $DEPLIST
# echo PROCESS_PACKAGES $PROCESS_PACKAGES
PROCESS_PACKAGES=$(echo $DEPLIST|depsort 2>$TMPDIR/depsort.log)
# echo PROCESS_PACKAGES $PROCESS_PACKAGES
#exit

#######################################################################
## Build each packages
##
## We don't do the 'deploy' phase in this pass, so they get all
## grouped later in the following pass
#######################################################################

export DEFAULT_PHASES="setup configure compile install deploy"

get_phase_names() {
	local pack=$1
	local ph=$2
	local res=""
	for role in $MINIFS_BOARD $MINIFS_BOARD_ROLE ; do
		res+="$role-$ph-$pack "
	done
	res+="$ph-$pack $ph-generic"
	echo $res
}

process_one_package() {
	local pack=$1
	local phases=$2
	for ph in $phases; do
		if [[ $ph == "deploy" ]]; then continue ;fi
		optional_one_of $(get_phase_names $pack $ph) || break
	done
}

for pack in $PROCESS_PACKAGES; do
	if [ ! -d $(get_package_dir $pack) ]; then
		echo "$BUILD/$dir" will not be built
		continue
	fi
	package $pack
		phases=$(hget $pack phases)
		phases=${phases:-$DEFAULT_PHASES}

		if [ "$COMMAND_PACKAGE" = "$PACKAGE" ]; then
			ph=$COMMAND_TARGET
			case "$ph" in
				shell|rebuild|clean)
					optional_one_of $(get_phase_names $pack $ph) || break
					;;
			esac
		fi
		process_one_package $pack "$phases"
	end_package
done

# Wait for every jobs to have finished
while true; do fg 2>/dev/null || break; done

#######################################################################
## Now, run the deploy phases for packages that wanted it
#######################################################################
echo "Deploying packages"
# this pass does just the 'deploy' bits
for pack in $PROCESS_PACKAGES; do
	if [ ! -d $(get_package_dir $pack) ]; then
		echo "$BUILD/$dir" will not be deployed
		continue;
	fi
	package $pack
		phases=$(hget $pack phases)
		phases=${phases:-$DEFAULT_PHASES}

		for ph in $phases; do
			if [[ $ph != "deploy" ]]; then continue ;fi
			optional_one_of $(get_phase_names $pack $ph) || break
		done
	end_package
done

# in minifs-script
optional board_compile

# in minifs-script
optional board_finish

chmod 0644 "$BUILD"/*.img "$BUILD"/*.ub 2>/dev/null
