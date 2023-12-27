#!/bin/bash

set -eo pipefail

SCRIPT=$(realpath "$0")
SCRIPTPATH=$(dirname "$SCRIPT")

jobs=$(nproc)
verbose='false'
build_lib='all'
clean='false'
install='false'
out_dir="$SCRIPTPATH/out"

print_usage() {
	printf "Usage: ./build.sh [options...]\n"
	printf "Options:\n"
	printf "  -v, --verbose    Verbose output\n"
	printf "  --clean          Clean build directory\n"
	printf "  -j, --jobs       Number of jobs to run simultaneously (default $jobs)\n"
	printf "  -b, --build      [all|protobuf|x264|x265|libvpx|opus|dav1d|svt-av1|opencv|ffmpeg] Build specific library (default: $build)\n"
	printf "  --prefix         Out Prefix (default: $out_dir)\n"
	printf "  --install        Install to prefix\n"
	printf "  -h, --help       Show this help message\n"
}

string_contain() { case $2 in *$1*) return 0 ;; *) return 1 ;; esac }

function parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-v | --verbose)
			verbose=1
			shift # Remove argument name from processing
			;;
		-j | --jobs)
			jobs=$2
			shift # Remove argument name
			shift # Remove argument value
			;;
		-b | --build)
			build_lib=$2
			shift # Remove argument name
			shift # Remove argument value
			;;
		-h | --help)
			print_usage
			exit 0
			;;
		--clean)
			clean='true'
			shift # Remove argument name
			;;
		--prefix)
			out_dir=$2
			shift # Remove argument name
			shift # Remove argument value
			;;
		--install)
			install='true'
			shift # Remove argument name
			;;
		*)
			echo "Unknown option: $1"
			print_usage
			exit 1
			;;
		esac
	done
}

function init() {
	parse_args "$@"

	OLD_ENV="$(env)"
	pushd "$SCRIPTPATH" >/dev/null

	if [ ! -z "$TERM" ] && tty -s; then
		tput civis
	fi

	function cleanup() {
		if [ ! -z "$TERM" ] && tty -s; then
			tput cnorm
		fi
		popd >/dev/null

		for line in $(env); do
			if [[ $line == *=* ]]; then
				unset $line
			fi
		done

		for line in $OLD_ENV; do
			if [[ $line == *=* ]]; then
				export $line
			fi
		done
	}

	trap cleanup EXIT

	mkdir -p $out_dir
	mkdir -p "$SCRIPTPATH/build"

	if [ "$verbose" = 'true' ]; then
		set -x
	fi

	if [ "$build_lib" = 'all' ]; then
		build_lib='protobuf x264 x265 libvpx opus dav1d svt-av1 opencv ffmpeg'
	fi
}

function check_cc() {
	printf "Checking CC "

	if [ ! -z "${CC}" ] || [ ! -z "${CXX}" ] || [ ! -z "${LD}" ]; then
		echo "[SKIPPED]"
		return
	fi

	if command -v clang &>/dev/null; then
		export CC=$(which clang)
		export CXX=$(which clang++) || $(which clang)
		export LD=$(which clang++) || $(which clang)
		echo "[DONE] (found clang)"
	elif command -v gcc &>/dev/null; then
		export CC=$(which gcc)
		export CXX=$(which g++)
		export LD=$(which g++) || $(which gcc)
		echo "[DONE] (found gcc)"
	elif command -v cc &>/dev/null; then
		export CC=$(which cc)
		export CXX=$(which c++)
		export LD=$(which c++) || $(which cc)
		echo "[DONE] (found cc)"
		exit 1
	fi
}

function settings() {
	echo "CC=$CC CXX=$CXX LD=$LD INSTALL_DIR=$out_dir"
}

function check_tool() {
	local name=$1

	printf "Checking $name "
	path=$(which $name)
	if [ -z "$path" ]; then
		echo "[NOT FOUND]"
		echo "$name could not be found, please install $name"
		exit 1
	fi
	echo "[FOUND] ($path)"
}

function spinner() {
	local name=$1
	local pid=$2

	local spinstr='|/-\'
	while ps -p $pid >/dev/null; do
		local temp=${spinstr#?}
		printf "[%c]  " "$spinstr"
		local spinstr=$temp${spinstr%"$temp"}
		sleep 0.75
		printf "\b\b\b\b\b"
	done
	printf "    \b\b\b\b"

	wait $pid || {
		echo "[FAILED]"
		echo "Failed to build $name, see $SCRIPTPATH/build/$name/build.log for more details"
		exit 1
	}

	echo "[DONE]"
}

function builder() {
	local name=$1
	local check_file=$2
	local build_inner=$3

	if [ ! -f "$SCRIPTPATH/$name/$check_file" ]; then
		echo "Failed to find $name source code, please run git submodule update --init --recursive"
		exit 1
	fi

	printf "Building $name "

	if string_contain $name $build_lib; then
		echo "[SKIPPED]"
		return
	fi

	local build_done=$SCRIPTPATH/build/$name/build-done
	local install_done=$SCRIPTPATH/build/$name/install-done

	local do_build='true'
	local do_install=$install

	local build_done_content=$(cat $build_done 2>/dev/null) || ""
	local install_done_content=$(cat $install_done 2>/dev/null) || ""

	local settings_value="$(settings)"

	if [ "$build_done_content" = "$settings_value" ]; then
		do_build='false'
	fi

	if [ "$clean" = 'true' ] || [ "$do_build" = 'true' ]; then
		rm -rf "$SCRIPTPATH/build/$name"
		do_build='true'
	fi

	if [ "$install_done_content" = "$settings_value" ]; then
		do_install='false'
	fi

	if [ "$do_build" = 'false' ] && [ "$do_install" = 'false' ]; then
		echo "[SKIPPED]"
		return
	fi

	mkdir -p $SCRIPTPATH/build/$name
	cd $SCRIPTPATH/build/$name

	function inner() {
		set -exo pipefail

		SOURCEPATH=$SCRIPTPATH/$1
		OUTPATH=$out_dir
		DOBUILD=$do_build
		DOINSTALL=$do_install
		$build_inner

		if [ "$DOBUILD" = 'true' ]; then
			echo $settings_value >$build_done
		fi

		if [ "$DOINSTALL" = 'true' ]; then
			echo $settings_value >$install_done
		fi
	}

	inner $name >$SCRIPTPATH/build/$name/build.log 2>&1 &
	spinner $name $!
}

function build_protobuf() {
	if [ "$DOBUILD" = 'true' ]; then
		cmake \
			-GNinja \
			-Dprotobuf_BUILD_TESTS=OFF \
			-DCMAKE_BUILD_TYPE=Release \
			-DABSL_PROPAGATE_CXX_STD=ON \
			-DCMAKE_INSTALL_PREFIX=$OUTPATH \
			$SOURCEPATH

		cmake --build . --config Release -j $jobs
	fi

	if [ "$DOINSTALL" = 'true' ]; then
		cmake --install . --config Release
	fi
}

function build_x264() {
	if [ "$DOBUILD" = 'true' ]; then
		$SOURCEPATH/configure \
			--prefix=$OUTPATH \
			--enable-static \
			--enable-pic \
			--bindir=$OUTPATH/bin

		make -j$jobs
	fi

	if [ "$DOINSTALL" = 'true' ]; then
		make install
	fi
}

function build_x265() {
	if [ "$DOBUILD" = 'true' ]; then
		cmake \
			-GNinja \
			-DCMAKE_BUILD_TYPE=Release \
			-DCMAKE_INSTALL_PREFIX=$OUTPATH \
			-DENABLE_SHARED=OFF \
			$SOURCEPATH/source

		cmake \
			--build . \
			--config Release \
			-j $jobs
	fi

	if [ "$DOINSTALL" = 'true' ]; then
		cmake \
			--install . \
			--config Release
	fi
}

function build_libvpx() {
	if [ "$DOBUILD" = 'true' ]; then
		$SOURCEPATH/configure \
			--prefix=$OUTPATH \
			--disable-examples \
			--disable-unit-tests \
			--enable-vp9-highbitdepth \
			--as=yasm \
			--enable-pic

		make -j$jobs
	fi

	if [ "$DOINSTALL" = 'true' ]; then
		make install
	fi
}

function build_opus() {
	if [ "$DOBUILD" = 'true' ]; then
		$SOURCEPATH/autogen.sh

		$SOURCEPATH/configure \
			--prefix=$OUTPATH \
			--enable-static \
			--disable-shared \
			--with-pic

		make -j$jobs
	fi

	if [ "$DOINSTALL" = 'true' ]; then
		make install
	fi
}

function build_dav1d() {
	if [ "$DOBUILD" = 'true' ]; then
		meson setup \
			-Denable_tools=false \
			-Denable_tests=false \
			--default-library=static \
			--prefix $OUTPATH \
			--libdir $OUTPATH/lib \
			$SOURCEPATH

		ninja -j $jobs
	fi

	if [ "$DOINSTALL" = 'true' ]; then
		ninja install
	fi
}

function build_svt_av1() {
	if [ "$DOBUILD" = 'true' ]; then
		cmake \
			-GNinja \
			-DCMAKE_INSTALL_PREFIX=$OUTPATH \
			-DCMAKE_BUILD_TYPE=Release \
			-DBUILD_DEC=OFF \
			-DBUILD_SHARED_LIBS=OFF \
			$SOURCEPATH

		cmake \
			--build . \
			--config Release \
			-j $jobs
	fi

	if [ "$DOINSTALL" = 'true' ]; then
		cmake \
			--install . \
			--config Release
	fi
}

function build_opencv() {
	if [ "$DOBUILD" = 'true' ]; then
		cmake \
			-GNinja \
			-DCMAKE_INSTALL_PREFIX=$OUTPATH \
			-DCMAKE_BUILD_TYPE=Release \
			-DBUILD_SHARED_LIBS=OFF \
			-DBUILD_LIST=core,imgproc,imgcodecs \
			$SOURCEPATH

		cmake \
			--build . \
			--config Release \
			-j $jobs
	fi

	if [ "$DOINSTALL" = 'true' ]; then
		cmake \
			--install . \
			--config Release
	fi
}

function build_ffmpeg() {
	if [ "$DOBUILD" = 'true' ]; then
		PKG_CONFIG_PATH="$OUTPATH/lib/pkgconfig" $SOURCEPATH/configure \
			--extra-libs="-lpthread -lm" \
			--prefix="$OUTPATH" \
			--pkg-config-flags="--static" \
			--extra-cflags="-I$OUTPATH/include" \
			--extra-ldflags="-L$OUTPATH/lib" \
			--disable-static \
			--enable-shared \
			--enable-pic \
			--enable-gpl \
			--enable-libx264 \
			--enable-libx265 \
			--enable-libvpx \
			--enable-libopus \
			--enable-libdav1d \
			--enable-libsvtav1 \
			--enable-nonfree

		make -j$jobs
	fi

	if [ "$DOINSTALL" = 'true' ]; then
		make install
	fi
}

init "$@"

check_cc
check_tool ninja
check_tool cmake
check_tool nasm

if string_contain "libvpx" $build_lib; then
	check_tool yasm
fi

if string_contain "dav1d" $build_lib; then
	check_tool meson
fi

echo "Settings:"
echo "  Build: $build_lib"
echo "  Clean: $clean"
echo "  Install: $install"
echo "  Prefix: $out_dir"
echo "  CC: $CC"
echo "  CXX: $CXX"
echo "  LD: $LD"
echo "  Jobs: $jobs"
echo ""

builder "protobuf" "CMakeLists.txt" build_protobuf
builder "x264" "configure" build_x264
builder "x265" "source/CMakeLists.txt" build_x265
builder "libvpx" "configure" build_libvpx
builder "opus" "autogen.sh" build_opus
builder "dav1d" "meson.build" build_dav1d
builder "SVT-AV1" "CMakeLists.txt" build_svt_av1
builder "opencv" "CMakeLists.txt" build_opencv
builder "FFmpeg" "configure" build_ffmpeg

echo "Done!"
