#!/bin/bash
# You may set, e.g. NPROC=2 and _JAVA_OPTIONS=-Xmx3061500416 to avoid java running out of heap with limited RAM
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
  repo sync -c --force-sync --no-clone-bundle --no-tags -j$NPROC || exit 1
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

	# Pack GSI OTA packing, signing & producing sha265sum plus json - quick and dirty
	# might be smoother with ota_from_target_files, but I didn't manage to
	TMPD=$(mktemp -d)
	rm -fr $TMPD/* $TMPD/.??*
	unzip -o -d $TMPD $BL/otatemplate.zip || exit 1
	if [ -d user-keys ]; then
	  (cd $OUT/obj/PACKAGING/target_files_intermediates/ && unzip ${1}-target_files-*.zip META/otakeys.txt && echo user-keys/releasekey.x509.pem > META/otakeys.txt && zip -r ${1}-target_files-*.zip META/otakeys.txt)
	 ./build/tools/releasetools/sign_target_files_apks -o -d user-keys \
	   $OUT/obj/PACKAGING/target_files_intermediates/${1}-target_files-*.zip \
	   $OUT/signed-target_files.zip
	 cat user-keys/releasekey.x509.pem > $TMPD/META-INF/com/android/otacert
	 KEYS="user-keys/release-keys"
	else
	 ln -s $OUT/obj/PACKAGING/target_files_intermediates/${1}-target_files-*.zip \
	    $OUT/signed-target_files.zip
	 cat build/target/product/security/testkey.x509.pem > $TMPD/META-INF/com/android/otacert
	 KEYS="security/testkey"
	fi
	unzip -o -d $TMPD $OUT/signed-target_files.zip SYSTEM/build.prop IMAGES/system.img || exit 1
	mv $TMPD/SYSTEM/build.prop $TMPD/system/build.prop && rm -fr $TMPD/SYSTEM || exit 1
	simg2img $TMPD/IMAGES/system.img $TMPD/system.img && rm -fr $TMPD/IMAGES || exit 1
	echo "ota-property-files=metadata:$(du -bs $TMPD | awk '{print $1}'):286" > $TMPD/META-INF/com/android/metadata
	echo "ota-required-cache=0" >> $TMPD/META-INF/com/android/metadata
	if [ $(echo $OUT | sed -e "s/.*_ab\/*$/ab/g") == "ab"  ]; then
	  echo "ota-type=AB" >> $TMPD/META-INF/com/android/metadata
	  cp vendor/lineage/prebuilt/common/bin/backuptool_ab.sh $TMPD/install/bin/
	  cp vendor/lineage/prebuilt/common/bin/backuptool_ab.functions $TMPD/install/bin/
	else    
	  echo "ota-type=BLOCK" >> $TMPD/META-INF/com/android/metadata
	fi
	cp vendor/lineage/prebuilt/common/bin/backuptool.sh $TMPD/install/bin/
	cp vendor/lineage/prebuilt/common/bin/backuptool.functions $TMPD/install/bin/
	cp vendor/lineage/prebuilt/common/bin/backuptool_postinstall.sh $TMPD/install/bin/
	JSON_NAME=$(grep ro.build.display.id $TMPD/system/build.prop | sed -e "s/ /\//g" | awk -F= '{print $2}')
	echo "post-build=$JSON_NAME:$KEYS" >> $TMPD/META-INF/com/android/metadata
	echo "post-sdk-level=29" >> $TMPD/META-INF/com/android/metadata
	echo "post-security-patch-level=$(grep ro.build.version.security_patch $TMPD/system/build.prop | sed -e "s/ /\//g" | awk -F= '{print $2}'):$KEYS" >> $TMPD/META-INF/com/android/metadata
	echo "post-timestamp=$(cat out/build_date.txt)" >> $TMPD/META-INF/com/android/metadata
	BUILD=lineage-17.1-$BUILD_DATE-UNOFFICIAL-${1}.zip
	(cd $TMPD; zip -r $OUT/ota_update.zip *) || exit 1
	rm -fr $TMPD
	if [ -d user-keys ]; then
	  build/tools/releasetools/sign_zip.py -k user-keys/releasekey $OUT/ota_update.zip ~/build-output/$BUILD || exit 1
	  rm -f $OUT/ota_update.zip
	else
	  mv -f $OUT/ota_update.zip ~/build-output/$BUILD || exit 1
	fi
        (cd ~/build-output; sha256sum "$BUILD" > "$BUILD.sha256sum") || exit 1
	if ! [ -z "$OTA_URL" ]; then
	  JSON_URL="$(echo $OTA_URL | sed -e "s/\(.*\)\/.*$/\1/")/$BUILD"
	  cat <<EOT > ~/build-output/$BUILD.json
{
  "response": [
    {
      "datetime": $(cat out/build_date.txt),
      "filename": "$BUILD",
      "id": "$JSON_NAME",
      "romtype": "unofficial",
      "size": $(du -bs ~/build-output/$BUILD | awk '{print $1}'),
      "url": "$JSON_URL",
      "version": "17.1"
    }
  ]
EOT
	  if [ $(echo $OUT | sed -e "s/.*_ab\/*$/ab/g") == "ab"  ]; then
	    cat <<EOT >> ~/build-output/$BUILD.json
,
  "name": "$JSON_NAME",
  "url": "$JSON_URL",
  "ab_install_type": "NON_STREAMING",
  "ab_config": {
      "force_switch_slot": true
  }
EOT
	  fi
	  echo "}" >> ~/build-output/$BUILD.json
	fi
} # of buildVariant()

#buildVariant treble_arm_avN
#buildVariant treble_arm_bvN
#buildVariant treble_a64_avN
#buildVariant treble_a64_bvN
#buildVariant treble_arm64_avN
buildVariant treble_arm64_bvN
(cd ~/build-output && ls | grep "lineage-*-$BUILD_DATE-*.zip*")

END=`date +%s`
ELAPSEDM=$(($(($END-$START))/60))
ELAPSEDS=$(($(($END-$START))-$ELAPSEDM*60))
echo "Buildbot completed in $ELAPSEDM minutes and $ELAPSEDS seconds"
echo ""
