#!/bin/bash
# You may want to set, e.g. NPROC=2 and _JAVA_OPTIONS=-Xmx3061500416 to avoid java running out of heap with limited RAM
# Set OTA_DEVICE to get the right pre-device into the OTA zip file
# Set OTA_URL in case you want to follow https://forum.xda-developers.com/chef-central/android/guide-include-ota-updating-lineageos-t3944648
# https://android.googlesource.com/platform/bootable/recovery/+/master/updater_sample/res/raw/sample.json

echo ""
echo "LineageOS 17.x Treble Buildbot"

CUSTOM_PACKAGES="GmsCore GsfProxy FakeStore MozillaNlpBackend NominatimNlpBackend com.google.android.maps.jar FDroid FDroidPrivilegedExtension AuroraServices"
START=`date +%s`
BUILD_DATE="$(date +%Y%m%d)"
BL=$PWD/treble_build_los
if [ -e $NPROC ]; then
    NPROC=`nproc --all`
fi

# Sync & patch only after 12h have passed
if [ `stat -c %Y .repo/.repo_fetchtimes.json` -lt $(expr `date +%s` - 43200) ]; then
  echo "ATTENTION: this script syncs repo"
  echo "Executing in 5 seconds - CTRL-C to exit"
  echo ""
  sleep 5

  echo "Remove previous changes of device/phh/treble, vendor/lineage, frameworks/base and prebuilts/prebuiltapks (if they exist)"
  for path in "device/phh/treble" "vendor/lineage" "frameworks/base" "prebuilts/prebuiltapks"; do
    (cd "$path" && git reset -q --hard && git clean -q -fd && git am --abort 2>/dev/null)
  done
  
  echo "Preparing local manifest"
  mkdir -p .repo/local_manifests
  cp $BL/manifest.xml .repo/local_manifests/manifest.xml
  echo ""

  echo "Syncing repos"
  repo sync -c --force-sync --no-clone-bundle --no-tags -j$NPROC
  # || touch --date="last week" .repo/.repo_fetchtimes.json; exit 1 GD todo
  echo ""
  
  echo "Preparing build environment"
  source build/envsetup.sh &> /dev/null
  echo ""

  echo "Reverting LOS FOD implementation"
  cd frameworks/base
  git am $BL/patches/0001-Squashed-revert-of-LOS-FOD-implementation.patch
  cd ../..
  cd frameworks/native
  git am $BL/patches/0001-Revert-surfaceflinger-Add-support-for-extension-lib.patch
  cd ../..
  cd vendor/lineage
  git revert 612c5a846ea5aed339fe1275c119ee111faae78c --no-edit # soong: Add flag for fod extension
  cd ../..
  echo ""

  echo "Applying PHH patches"
  rm -f device/*/sepolicy/common/private/genfs_contexts
  cd device/phh/treble
  git clean -fdx
  bash generate.sh lineage
  cd ../../..
  bash ~/treble_experimentations/apply-patches.sh treble_patches
  echo ""

  echo "Applying universal patches"
  cd frameworks/base
  git am $BL/patches/0001-UI-Revive-navbar-layout-tuning-via-sysui_nav_bar-tun.patch
  git am $BL/patches/0001-Disable-vendor-mismatch-warning.patch
  # FAKE_SIGNATURE permission can be obtained only by privileged system apps
  # git am $BL/patches/0001-core-Add-support-for-MicroG.patch
  TMPF=$(mktemp)
  sed 's/android:protectionLevel="dangerous"/android:protectionLevel="signature|privileged"/' $BL/patches/0001-core-Add-support-for-MicroG.patch > $TMPF
  git am $TMPF
  rm -f $TMPF
  git am $BL/patches/0001-Add-libbase-to-libhwui-deps.patch
  cd ../..
  cd lineage-sdk
  git am $BL/patches/0001-sdk-Invert-per-app-stretch-to-fullscreen.patch
  cd ..
  cd packages/apps/LineageParts
  git am $BL/patches/0001-LineageParts-Invert-per-app-stretch-to-fullscreen.patch
  cd ../../..
# Commented out for security resons
# https://source.android.com/devices/tech/config/perms-whitelist
#  cd vendor/lineage
#  git am $BL/patches/0001-vendor_lineage-Log-privapp-permissions-whitelist-vio.patch
#  cd ../..
  echo ""

  echo "Applying GSI-specific patches"
  cd build/make
  git am $BL/patches/0001-build-Don-t-handle-apns-conf.patch
  cd ../..
  cd device/phh/treble
  git revert 82b15278bad816632dcaeaed623b569978e9840d --no-edit # Update lineage.mk for LineageOS 16.0
  git am $BL/patches/0001-Remove-fsck-SELinux-labels.patch
  git am $BL/patches/0001-treble-Add-overlay-lineage.patch
  git am $BL/patches/0001-treble-Don-t-specify-config_wallpaperCropperPackage.patch
  git am $BL/patches/0001-TEMP-treble-Fix-init.treble-environ.rc-hardcode-for-.patch
  cd ../../..
  cd external/tinycompress
  git revert 82c8fbf6d3fb0a017026b675adf2cee3f994e08a --no-edit # tinycompress: Use generated kernel headers
  cd ../..
  cd frameworks/native
  git revert 581c22f979af05e48ad4843cdfa9605186d286da --no-edit # Add suspend_resume trace events to the atrace 'freq' category.
  cd ../..
  cd hardware/lineage/interfaces
  git am $BL/patches/0001-cryptfshw-Remove-dependency-on-generated-kernel-head.patch
  cd ../../..
  cd system/hardware/interfaces
  git revert 5c145c49cc83bfe37c740bcfd3f82715ee051122 --no-edit # system_suspend: start early
  cd ../../..
  cd system/sepolicy
  git revert d12551bf1a6e8a9ece6bbb98344a27bde7f9b3e1 --no-edit # sepolicy: Relabel wifi. properties as wifi_prop
  cd ../..
  cd vendor/lineage
  git am $BL/patches/0001-build_soong-Disable-generated_kernel_headers.patch
  cd ../..
  echo ""

  echo "Adding microg"
  mkdir -p "vendor/lineage/overlay/microg/"
  sed -i "1s;^;PRODUCT_PACKAGE_OVERLAYS := vendor/lineage/overlay/microg\n;" "vendor/lineage/config/common.mk"
  # Override device-specific settings for the location providers
  mkdir -p "vendor/lineage/overlay/microg/frameworks/base/core/res/res/values/"
  cp $BL/patches/frameworks_base_config.xml "vendor/lineage/overlay/microg/frameworks/base/core/res/res/values/config.xml"

  # Set a custom updater URI if a OTA URL is provided
  if ! [ -z "$OTA_URL" ]; then
    echo "Set custom updater URI to $OTA"
    updater_url_overlay_dir="vendor/lineage/overlay/microg/packages/apps/Updater/res/values/"
    mkdir -p "$updater_url_overlay_dir"

    if [ -n "$(grep updater_server_url packages/apps/Updater/res/values/strings.xml)" ]; then
      # "New" updater configuration: full URL (with placeholders {device}, {type} and {incr})
#      sed "s|{name}|updater_server_url|g; s|{url}|$OTA_URL/v1/{device}/{type}/{incr}|g" $BL/patches/packages_updater_strings.xml > "$updater_url_overlay_dir/strings.xml"
      sed "s|{name}|updater_server_url|g; s|{url}|$OTA_URL|g" $BL/patches/packages_updater_strings.xml > "$updater_url_overlay_dir/strings.xml"
    elif [ -n "$(grep conf_update_server_url_def packages/apps/Updater/res/values/strings.xml)" ]; then
      # "Old" updater configuration: just the URL
      sed "s|{name}|conf_update_server_url_def|g; s|{url}|$OTA_URL|g" $BL/patches/packages_updater_strings.xml > "$updater_url_overlay_dir/strings.xml"
    else
      echo ">> [$(date)] ERROR: no known Updater URL property found"
      exit 1
    fi
  fi
  # Add custom packages to be installed
  if ! [ -z "$CUSTOM_PACKAGES" ]; then
    echo "Adding custom packages ($CUSTOM_PACKAGES)"
    sed -i "1s;^;PRODUCT_PACKAGES += $CUSTOM_PACKAGES\n\n;" "vendor/lineage/config/common.mk"
  fi
  # Sign if user-keys dir is present,
  # e.g. mkdir user-keys && cd user-keys && ln -s ../build/make/target/product/security/* && ln -s ~/android-certs/* .; cd ..
  # https://source.android.com/devices/tech/ota/sign_builds
  if [ -d user-keys ]; then
    sed -i "1s;^;PRODUCT_DEFAULT_DEV_CERTIFICATE := user-keys/releasekey\nPRODUCT_OTA_PUBLIC_KEYS := user-keys/releasekey\n\n;" "vendor/lineage/config/common.mk"
  fi
  unzip -o $BL/AuroraServices.zip
  if [ -f ./user-scripts/before.sh ]; then
    echo "Running before.sh"
    ./user-scripts/before.sh
  fi
  
  echo "CHECK PATCH STATUS NOW!"
  sleep 5
  echo ""
fi

echo "Setting up build environment"
source build/envsetup.sh &> /dev/null
echo ""

export WITHOUT_CHECK_API=true
# Commented out for security resons
#export WITH_SU=true
mkdir -p ~/build-output/

buildVariant() {
	lunch ${1}-userdebug || exit 1
	make installclean || exit 1
	make -j$NPROC dist || exit 1

	BUILD=lineage-17.1-$BUILD_DATE-UNOFFICIAL-${1}
	if ! [ -z "$OTA_URL" || -z "$OTA_DEVICE" ]; then
	  # GSI OTA packing, signing & producing sha265sums plus json - quick and dirty
	  # GSI target_files need to be amended as done below to enable ota_from_target_files running properly ...
	  TMPD=$(mktemp -d)
	  rm -fr $TMPD/* $TMPD/.??*
	  cp -f $OUT/obj/PACKAGING/target_files_intermediates/${1}-target_files-*.zip /tmp/signed-target_files.zip
	  # Remove obsolete files for this purpose
	  zip -d /tmp/signed-target_files.zip IMAGES/cache.img IMAGES/vendor.img IMAGES/vendor.map
	  # Force right OTA device ro.product.device
	  unzip -o -d $TMPD /tmp/signed-target_files.zip SYSTEM/build.prop &&
	      grep -v "^[^\#]*ro.product.device" $TMPD/SYSTEM/build.prop > ${TMPD}__ &&
	      mv -f ${TMPD}__ $TMPD/SYSTEM/build.prop &&
	      echo "ro.product.device=$OTA_DEVICE" >> $TMPD/SYSTEM/build.prop
	  unzip -o -d $TMPD /tmp/signed-target_files.zip META/misc_info.txt &&
	      grep -v "^[^\#]*override_device" $TMPD/META/misc_info.txt > ${TMPD}__ &&
	      mv -f ${TMPD}__ $TMPD/META/misc_info.txt &&
	      echo "override_device=$OTA_DEVICE" >> $TMPD/META/misc_info.txt
	  # Only the system partion shall be fed into OTA
	  echo "system" > $TMPD/META/ab_partitions.txt
	  # Add update_engine config data
	  echo "PAYLOAD_MAJOR_VERSION=2" > $TMPD/META/update_engine_config.txt
	  echo "PAYLOAD_MINOR_VERSION=4" >> $TMPD/META/update_engine_config.txt
	  # Add postinstall config
	  cat <<EOT > $TMPD/META/postinstall_config.txt
RUN_POSTINSTALL_system=true
POSTINSTALL_PATH_system=system/bin/otapreopt_script
FILESYSTEM_TYPE_system=ext4
POSTINSTALL_OPTIONAL_system=true
EOT
	  if [ -d user-keys ]; then
#	    echo "vbmeta" >> $TMPD/META/ab_partitions.txt
	    echo user-keys/releasekey.x509.pem > $TMPD/META/otakeys.txt
# No extra recovery-only key(s) vendor/lineage/build/target/product/security/lineage.x509.pem needed
	    (cd $TMPD; zip -r ../signed-target_files.zip *)
	    ./build/tools/releasetools/sign_target_files_apks -o -d user-keys \
							      /tmp/signed-target_files.zip \
							      $OUT/signed-target_files.zip || exit 1
	    KEYS="user-keys/release-keys"
	  else
	    # Remove more obsolete files for this purpose
	    zip -d /tmp/signed-target_files.zip IMAGES/vbmeta.img META/otakeys.txt
	    # Include the amendments above and sign
	    (cd $TMPD; zip -r ../signed-target_files.zip *)
	    ./build/tools/releasetools/sign_target_files_apks \
		/tmp/signed-target_files.zip \
		$OUT/signed-target_files.zip || exit 1
	    KEYS="security/testkey"
	  fi
	  # Extract new system.img
	  unzip -o -d $TMPD $OUT/signed-target_files.zip IMAGES/system.img
	  mv -f $TMPD/IMAGES/system.img $OUT
	  # Generate .json file
	  JSON_NAME=$(grep ro.build.display.id $OUT/obj/PACKAGING/target_files_intermediates/${1}-target_files-*/SYSTEM/build.prop | sed -e "s/ /\//g" | awk -F= '{print $2}')
	  ./build/make/tools/releasetools/ota_from_target_files $OUT/signed-target_files.zip $OUT/ota_update.zip || exit 1
	  # Note: Testing to install the payload.bin on the device can be done via 
	  # update_engine_client --payload=file:///data/ota_package/payload.bin --update --follow --headers="FILE_HASH=(...)"
	  rm -fr $TMPD /tmp/signed-target_files.zip
	  mv -f $OUT/ota_update.zip ~/build-output/$BUILD.zip || exit 1
          (cd ~/build-output; sha256sum "$BUILD.zip" > "$BUILD.zip.sha256sum") || exit 1
	  JSON_URL="$(echo $OTA_URL | sed -e "s/\(.*\)\/.*$/\1/")/$BUILD.zip"
	  cat <<EOT > ~/build-output/$BUILD.zip.json
{
  "response": [
    {
      "datetime": $(cat out/build_date.txt),
      "filename": "$BUILD.zip",
      "id": "$JSON_NAME",
      "romtype": "unofficial",
      "size": $(du -bs ~/build-output/$BUILD.zip | awk '{print $1}'),
      "url": "$JSON_URL",
      "version": "17.1"
    }
  ]
}
EOT
	fi
	cp -f $OUT/system.img ~/build-output/$BUILD.img || exit 1
        (cd ~/build-output; sha256sum "$BUILD.img" > "$BUILD.img.sha256sum") || exit 1
} # of buildVariant()

#buildVariant treble_arm_avN
#buildVariant treble_arm_bvN
#buildVariant treble_a64_avN
#buildVariant treble_a64_bvN
#buildVariant treble_arm64_avN
buildVariant treble_arm64_bvN

END=`date +%s`
ELAPSEDM=$(($(($END-$START))/60))
ELAPSEDS=$(($(($END-$START))-$ELAPSEDM*60))
echo "Buildbot completed in $ELAPSEDM minutes and $ELAPSEDS seconds"
echo ""
(cd ~/build-output && ls | grep "lineage-17.1-$BUILD_DATE-*")
