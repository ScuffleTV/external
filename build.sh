#!/bin/bash

set -eo pipefail

SCRIPT=$(realpath "$0")
SCRIPTPATH=$(dirname "$SCRIPT")

jobs=$(nproc)
verbose='false'
build='all'
clean='false'

print_usage() {
	printf "Usage: ./build.sh [options...]\n"
	printf "Options:\n"
	printf "  -v, --verbose  Verbose output\n"
	printf "  --clean        Clean build directory\n"
	printf "  -j, --jobs     Number of jobs to run simultaneously (default $(nproc))\n"
	printf "  -b, --build    [all|protobuf|x264|x265|libvpx|opus|dav1d|svt-av1|opencv|ffmpeg] Build specific library (default: all)\n"
	printf "  -h, --help     Show this help message\n"
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

	tput civis

	function cleanup() {
		tput cnorm
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

	mkdir -p $SCRIPTPATH/out
	mkdir -p $SCRIPTPATH/build

	if [ "$verbose" = 'true' ]; then
		set -x
	fi

	if [ "$clean" = 'true' ]; then
		rm -rf $SCRIPTPATH/build $SCRIPTPATH/out
	fi

	if [ "$build_lib" = 'all' ]; then
		build_lib='protobuf x264 x265 libvpx opus dav1d svt-av1 opencv ffmpeg'
	fi
}

function check_cmake() {
	if ! command -v cmake &>/dev/null; then
		echo "cmake could not be found, please install cmake"
		exit
	fi
}

function check_ninja() {
	if ! command -v ninja &>/dev/null; then
		echo "ninja could not be found, please install ninja"
		exit
	fi
}

function check_cc() {
	printf "Checking CC "

	if [ ! -z "$CC" ] || [ ! -z "$CXX" ] || [ ! -z "$LD" ]; then
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

function check_yasm() {
	if ! command -v yasm &>/dev/null; then
		echo "yasm could not be found, please install yasm"
		exit
	fi
}

function check_nasm() {
	if ! command -v nasm &>/dev/null; then
		echo "nasm could not be found, please install nasm"
		exit
	fi
}

function check_meson() {
	if ! command -v meson &>/dev/null; then
		echo "meson could not be found, please install meson"
		exit
	fi
}

function spinner() {
	local name=$1
	local pid=$2

	local spinstr='|/-\'
	while ps -p $pid >/dev/null; do
		local temp=${spinstr#?}
		printf " [%c]  " "$spinstr"
		local spinstr=$temp${spinstr%"$temp"}
		sleep 0.75
		printf "\b\b\b\b\b\b"
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

	if [ -f "$SCRIPTPATH/build/$name/build-done" ]; then
		echo "[CACHED]"
		return
	fi

	mkdir -p $SCRIPTPATH/build/$name
	cd $SCRIPTPATH/build/$name

	function inner() {
		set -exo pipefail
		SOURCEPATH=$SCRIPTPATH/$1
		OUTPATH=$SCRIPTPATH/out
		$build_inner
	}

	inner $name >$SCRIPTPATH/build/$name/build.log 2>&1 &
	spinner $name $!
	touch $SCRIPTPATH/build/$name/build-done
}

function build_protobuf() {
	cmake \
		-GNinja \
		-Dprotobuf_BUILD_TESTS=OFF \
		-DCMAKE_BUILD_TYPE=Release \
		-DABSL_PROPAGATE_CXX_STD=ON \
		-DCMAKE_INSTALL_PREFIX=$OUTPATH \
		$SOURCEPATH

	cmake --build . --target install --config Release -j $jobs
}

function build_x264() {
	$SOURCEPATH/configure \
		--prefix=$OUTPATH \
		--enable-static \
		--enable-pic \
		--bindir=$OUTPATH/bin

	make -j$jobs
	make install
}

function build_x265() {
	cmake \
		-DCMAKE_BUILD_TYPE=Release \
		-GNinja \
		-DCMAKE_INSTALL_PREFIX=$OUTPATH \
		-DENABLE_SHARED=OFF \
		$SOURCEPATH/source

	cmake \
		--build . \
		--target install \
		--config Release \
		-j $jobs
}

function build_libvpx() {
	$SOURCEPATH/configure \
		--prefix=$OUTPATH \
		--disable-examples \
		--disable-unit-tests \
		--enable-vp9-highbitdepth \
		--as=yasm \
		--enable-pic

	make -j$jobs
	make install
}

function build_opus() {
	$SOURCEPATH/autogen.sh

	$SOURCEPATH/configure \
		--prefix=$OUTPATH \
		--enable-static \
		--disable-shared \
		--with-pic

	make -j$jobs
	make install
}

function build_dav1d() {
	meson setup \
		-Denable_tools=false \
		-Denable_tests=false \
		--default-library=static \
		--prefix $OUTPATH \
		--libdir $OUTPATH/lib \
		$SOURCEPATH

	ninja install -j $jobs
}

function build_svt_av1() {
	cmake \
		-GNinja \
		-DCMAKE_INSTALL_PREFIX=$OUTPATH \
		-DCMAKE_BUILD_TYPE=Release \
		-DBUILD_DEC=OFF \
		-DBUILD_SHARED_LIBS=OFF \
		$SOURCEPATH

	cmake \
		--build . \
		--target install \
		--config Release \
		-j $jobs
}

function build_opencv() {
	cmake \
		-GNinja \
		-DCMAKE_INSTALL_PREFIX=$OUTPATH \
		-DCMAKE_BUILD_TYPE=Release \
		-DBUILD_SHARED_LIBS=OFF \
		-DOPENCV_GENERATE_PKGCONFIG=ON \
		-DBUILD_LIST=core,imgproc,imgcodecs \
		$SOURCEPATH

	cmake \
		--build . \
		--target install \
		--config Release \
		-j $jobs
}

function build_ffmpeg() {
	PATH="$BIN_DIR:$PATH" PKG_CONFIG_PATH="$OUTPATH/lib/pkgconfig" $SOURCEPATH/configure \
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
	make install
}

init "$@"

check_cc
check_ninja
check_cmake
check_yasm
check_nasm
check_meson

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
