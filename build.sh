#!/bin/bash
#
# AntaresCore Kernel build script
#

export ARCH=arm64
export SUBARCH=$ARCH
export CPU_COUNT=$(($(nproc) + 1))
export HOSTNAME=`uname -n`
export KERNEL_DIR=`readlink -f .`
export INITRAMFS_SOURCE=`readlink -f ..`/ramdisk-h815
export INITRAMFS_TMP=/tmp/initramfs_source
export KERNEL_CONFIG=antares_defconfig
export CMDLINE="console=ttyHSL0,115200,n8 androidboot.console=ttyHSL0 androidboot.hardware=p1 androidboot.selinux=enforcing user_debug=31 ehci-hcd.park=3 lpm_levels.sleep_disabled=1 cpu_max_a53=1632000 cpu_max_a57=2016000"

# Kernel version
export DEFVER="1.3"

setup() {
    if [ "$CROSS_COMPILE" == "" ]; then
	echo ""
	echo "What GCC version do you want to use?"
	select tcver in "4.9" "5.3"; do
	    case $tcver in
		"4.9" ) export TCVER="4.9"; break;;
		"5.3" ) export TCVER="5.3"; break;;
	    esac
	done
	export CROSS_COMPILE=`readlink -f ..`/aarch64-linux-android-$TCVER/bin/aarch64-linux-android-
    fi
}

buildKernel() {
    if [ "$debug" == "true" ]; then
	export PACKAGE_DIR=$KERNEL_DIR/OUT/debug
	export VERSION=-v$DEFVER-H815-LGE-MM-6.0-DEBUG
    else
	export PACKAGE_DIR=$KERNEL_DIR/OUT/release
	export VERSION=-v$DEFVER-H815-LGE-MM-6.0
    fi
	
    time_start=$(date +%s.%N)

    echo "Setup package directory"
    mkdir -p $PACKAGE_DIR/system/lib/modules

    if [ -d $INITRAMFS_TMP ]; then
	echo "Removing old temp initramfs_source"
	rm -rf $INITRAMFS_TMP
    fi

    if [ ! -d $INITRAMFS_SOURCE ]; then
	echo "No ramdisk source found! Kernel cannot be built!"
	echo -e "Put source in \e[91m$INITRAMFS_SOURCE\e[39m"
	exit 1
    fi

    # Remove all old modules before building
    for i in `find $KERNEL_DIR/ -name "*.ko"`; do
	rm -f $i
    done

    for i in `find $PACKAGE_DIR/system/lib/modules/ -name "*.ko"`; do
	rm -f $i
    done

    # Copy initramfs source files to temporary directory
    cp -ax $INITRAMFS_SOURCE $INITRAMFS_TMP

    # Clear git repo from temporary initramfs data
    if [ -d $INITRAMFS_TMP/.git ]; then
	rm -rf $INITRAMFS_TMP/.git
    fi

    # Copy config if not found
    if [ ! -f $KERNEL_DIR/.config ]; then
	cp $KERNEL_DIR/arch/arm64/configs/$KERNEL_CONFIG $KERNEL_DIR/.config
    fi

    # Apply kernel version number
    sed -i 's/-AntaresCore[^\]*/-AntaresCore'$VERSION'"/' $KERNEL_DIR/.config

    # Remove previous zImage files
    echo "Removing old kernel image"
    if [ -e $KERNEL_DIR/arch/arm64/boot/Image ]; then
	rm $KERNEL_DIR/arch/arm64/boot/Image
	rm $KERNEL_DIR/arch/arm64/boot/Image.gz
	rm $KERNEL_DIR/arch/arm64/boot/Image.gz-dtb
    fi

    if [ -e $PACKAGE_DIR/boot.img ]; then
	rm $PACKAGE_DIR/boot.img
    fi

    echo "Making kernel"
    make -j$CPU_COUNT || exit 1

    echo "Copying modules to output package"
    for i in `find $KERNEL_DIR -name '*.ko'`; do
	cp -av $i $PACKAGE_DIR/system/lib/modules/
    done

    for i in `find $PACKAGE_DIR/system/lib/modules/ -name '*.ko'`; do
	${CROSS_COMPILE}strip --strip-unneeded $i
	${CROSS_COMPILE}strip --strip-debug $i
    done

    chmod 644 $PACKAGE_DIR/system/lib/modules/*

    if [ -e $KERNEL_DIR/arch/arm64/boot/Image ]; then
	echo "Copying kernel image to output package"
	cp $KERNEL_DIR/arch/arm64/boot/Image $PACKAGE_DIR/Image
	echo "Making bootimage"
	if [ -e $KERNEL_DIR/scripts/dtc/dtc ]; then
	    ./dtbtool --force-v3 -s 4096 -p $KERNEL_DIR/scripts/dtc/ -o $PACKAGE_DIR/dt.img $KERNEL_DIR/arch/arm64/boot/dts/
	else
	    echo -e "Missing DTC binary in \e[91m$KERNEL_DIR/scripts/dtc\e[39m"
	fi
	./mkbootfs $INITRAMFS_TMP | gzip > $PACKAGE_DIR/ramdisk.gz
	./mkbootimg --kernel $PACKAGE_DIR/Image --ramdisk $PACKAGE_DIR/ramdisk.gz --cmdline "$CMDLINE" --board msm8992 --base 0x00078000 --pagesize 4096 --dt $PACKAGE_DIR/dt.img  --kernel_offset 0x00008000 --ramdisk_offset 0x01f88000 --tags_offset 0x01d88000 --output $PACKAGE_DIR/boot.img
	cd $PACKAGE_DIR
	
	echo "Cleaning temp kernel data"
	if [ -e ramdisk.gz ]; then
	    rm ramdisk.gz
	fi
	
	if [ -e Image ]; then
	    rm Image
	fi
	
	if [ -e dt.img ]; then
	    rm dt.img
	fi
	
	echo "Removing old output package zip files"
	for i in `find $PACKAGE_DIR/ -name '*.zip'`; do
	    rm $i
	done
	
	FILENAME=Kernel-AntaresCore$VERSION-`date +"[%Y-%m-%d]-[%H-%M]"`.zip
	zip -r $FILENAME .

	time_end=$(date +%s.%N)
	echo -e "${BLDYLW}Total time elapsed: ${TCTCLR}${TXTGRN}$(echo "($time_end - $time_start) / 60"|bc ) ${TXTYLW}minutes${TXTGRN} ($(echo "$time_end - $time_start"|bc ) ${TXTYLW}seconds) ${TXTCLR}"
	
	FILESIZE=$(stat -c%s "$FILENAME")
	echo "Size of $FILENAME = $FILESIZE bytes."
	
	if [ -e /usr/bin/adb ]; then
	    read -t 5 -p "Do you want to push the new package now? (5 sec timeout [y/n])"
	    if [ "$REPLY" == "y" ]; then
	        echo "Waiting for device..."
	        adb wait-for-device
	        adb push $FILENAME /sdcard/
	        echo "$FILENAME pushed in /sdcard!"
	    fi
	fi
	
	cd $KERNEL_DIR
    else
	echo "Operation failed! No kernel image found!"
    fi
}

clean() {
    export KERNEL_IMAGE_DIR=$KERNEL_DIR/arch/arm64/boot
    echo "Cleaning out"
    cp -pv .config .config.bkp
    make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE mrproper
    cp -pv .config.bkp .config
    make clean && make mrproper
    rm -f $KERNEL_IMAGE_DIR/Image
    rm -f $KERNEL_IMAGE_DIR/Image.gz
    rm -f $KERNEL_IMAGE_DIR/Image.gz-dtb
    rm -rf $KERNEL_DIR/kernel/usr
    rm -rf $PACKAGE_DIR/system
    rm -f $PACKAGE_DIR/*.zip
    rm -f $PACKAGE_DIR/boot.img

    for i in `find . -type f \( -iname \*.rej \
				    -o -iname \*.orig \
				    -o -iname \*.bkp \
				    -o -iname \*.ko \
				    -o -iname \*.c.BACKUP.[0-9]*.c \
				    -o -iname \*.c.BASE.[0-9]*.c \
				    -o -iname \*.c.LOCAL.[0-9]*.c \
				    -o -iname \*.c.REMOTE.[0-9]*.c \
				    -o -iname \*.org \)`; do
	    rm -vf $i
    done

    # Clear ccache
    read -t 10 -p "Do you want to clear ccache? (10 sec timeout [y/n])"
    if [ "$REPLY" == "y" ]; then
	ccache -C
    fi
}

echo ""
echo -e "\e[1;91mWelcome to AntaresCore kernel build script"
echo -e "\e[0m"
echo ""
echo -e "Build system: \e[96m$HOSTNAME\e[39m"
echo -e "CPU count: \e[91m$(($CPU_COUNT - 1))\e[39m"
echo ""
echo  "What do you want to do?"
select choice in "Build kernel" "Build kernel (debug)" "Clean" "Exit"; do 
    case $choice in
	"Build kernel" ) setup; buildKernel; break;;
	"Build kernel (debug)" ) debug=true; setup; buildKernel; break;;
	"Clean" ) setup; clean; break;;
	"Exit" ) exit 0; break;;
    esac
done

exit 0
