#!/bin/sh
set -e
set -u
set -o pipefail

function on_error {
  echo "$(realpath -mq "${0}"):$1: error: Unexpected failure"
}
trap 'on_error $LINENO' ERR


# This protects against multiple targets copying the same framework dependency at the same time. The solution
# was originally proposed here: https://lists.samba.org/archive/rsync/2008-February/020158.html
RSYNC_PROTECT_TMP_FILES=(--filter "P .*.??????")


variant_for_slice()
{
  case "$1" in
  "AgoraAiEchoCancellationExtension.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  "AgoraAiEchoCancellationLLExtension.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  "AgoraAiNoiseSuppressionExtension.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  "AgoraAiNoiseSuppressionLLExtension.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  "AgoraAudioBeautyExtension.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  "AgoraClearVisionExtension.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  "AgoraContentInspectExtension.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  "AgoraFaceCaptureExtension.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  "AgoraFaceDetectionExtension.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  "AgoraLipSyncExtension.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  "AgoraRtcKit.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  "Agorafdkaac.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  "Agoraffmpeg.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  "AgoraSoundTouch.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  "AgoraScreenCaptureExtension.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  "AgoraSpatialAudioExtension.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  "AgoraVideoQualityAnalyzerExtension.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  "AgoraVideoAv1DecoderExtension.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  "AgoraVideoAv1EncoderExtension.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  "AgoraVideoDecoderExtension.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  "video_dec.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  "AgoraVideoEncoderExtension.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  "video_enc.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  "AgoraVideoSegmentationExtension.xcframework/macos-arm64_x86_64")
    echo ""
    ;;
  esac
}

archs_for_slice()
{
  case "$1" in
  "AgoraAiEchoCancellationExtension.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  "AgoraAiEchoCancellationLLExtension.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  "AgoraAiNoiseSuppressionExtension.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  "AgoraAiNoiseSuppressionLLExtension.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  "AgoraAudioBeautyExtension.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  "AgoraClearVisionExtension.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  "AgoraContentInspectExtension.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  "AgoraFaceCaptureExtension.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  "AgoraFaceDetectionExtension.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  "AgoraLipSyncExtension.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  "AgoraRtcKit.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  "Agorafdkaac.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  "Agoraffmpeg.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  "AgoraSoundTouch.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  "AgoraScreenCaptureExtension.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  "AgoraSpatialAudioExtension.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  "AgoraVideoQualityAnalyzerExtension.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  "AgoraVideoAv1DecoderExtension.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  "AgoraVideoAv1EncoderExtension.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  "AgoraVideoDecoderExtension.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  "video_dec.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  "AgoraVideoEncoderExtension.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  "video_enc.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  "AgoraVideoSegmentationExtension.xcframework/macos-arm64_x86_64")
    echo "arm64 x86_64"
    ;;
  esac
}

copy_dir()
{
  local source="$1"
  local destination="$2"

  # Use filter instead of exclude so missing patterns don't throw errors.
  echo "rsync --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --links --filter \"- CVS/\" --filter \"- .svn/\" --filter \"- .git/\" --filter \"- .hg/\" \"${source}*\" \"${destination}\""
  rsync --delete -av "${RSYNC_PROTECT_TMP_FILES[@]}" --links --filter "- CVS/" --filter "- .svn/" --filter "- .git/" --filter "- .hg/" "${source}"/* "${destination}"
}

SELECT_SLICE_RETVAL=""

select_slice() {
  local xcframework_name="$1"
  xcframework_name="${xcframework_name##*/}"
  local paths=("${@:2}")
  # Locate the correct slice of the .xcframework for the current architectures
  local target_path=""

  # Split archs on space so we can find a slice that has all the needed archs
  local target_archs=$(echo $ARCHS | tr " " "\n")

  local target_variant=""
  if [[ "$PLATFORM_NAME" == *"simulator" ]]; then
    target_variant="simulator"
  fi
  if [[ ! -z ${EFFECTIVE_PLATFORM_NAME+x} && "$EFFECTIVE_PLATFORM_NAME" == *"maccatalyst" ]]; then
    target_variant="maccatalyst"
  fi
  for i in ${!paths[@]}; do
    local matched_all_archs="1"
    local slice_archs="$(archs_for_slice "${xcframework_name}/${paths[$i]}")"
    local slice_variant="$(variant_for_slice "${xcframework_name}/${paths[$i]}")"
    for target_arch in $target_archs; do
      if ! [[ "${slice_variant}" == "$target_variant" ]]; then
        matched_all_archs="0"
        break
      fi

      if ! echo "${slice_archs}" | tr " " "\n" | grep -F -q -x "$target_arch"; then
        matched_all_archs="0"
        break
      fi
    done

    if [[ "$matched_all_archs" == "1" ]]; then
      # Found a matching slice
      echo "Selected xcframework slice ${paths[$i]}"
      SELECT_SLICE_RETVAL=${paths[$i]}
      break
    fi
  done
}

install_xcframework() {
  local basepath="$1"
  local name="$2"
  local package_type="$3"
  local paths=("${@:4}")

  # Locate the correct slice of the .xcframework for the current architectures
  select_slice "${basepath}" "${paths[@]}"
  local target_path="$SELECT_SLICE_RETVAL"
  if [[ -z "$target_path" ]]; then
    echo "warning: [CP] $(basename ${basepath}): Unable to find matching slice in '${paths[@]}' for the current build architectures ($ARCHS) and platform (${EFFECTIVE_PLATFORM_NAME-${PLATFORM_NAME}})."
    return
  fi
  local source="$basepath/$target_path"

  local destination="${PODS_XCFRAMEWORKS_BUILD_DIR}/${name}"

  if [ ! -d "$destination" ]; then
    mkdir -p "$destination"
  fi

  copy_dir "$source/" "$destination"
  echo "Copied $source to $destination"
}

install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/AgoraAiEchoCancellationExtension.xcframework" "AgoraRtcEngine_macOS/AIAEC" "framework" "macos-arm64_x86_64"
install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/AgoraAiEchoCancellationLLExtension.xcframework" "AgoraRtcEngine_macOS/AIAECLL" "framework" "macos-arm64_x86_64"
install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/AgoraAiNoiseSuppressionExtension.xcframework" "AgoraRtcEngine_macOS/AINS" "framework" "macos-arm64_x86_64"
install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/AgoraAiNoiseSuppressionLLExtension.xcframework" "AgoraRtcEngine_macOS/AINSLL" "framework" "macos-arm64_x86_64"
install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/AgoraAudioBeautyExtension.xcframework" "AgoraRtcEngine_macOS/AudioBeauty" "framework" "macos-arm64_x86_64"
install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/AgoraClearVisionExtension.xcframework" "AgoraRtcEngine_macOS/ClearVision" "framework" "macos-arm64_x86_64"
install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/AgoraContentInspectExtension.xcframework" "AgoraRtcEngine_macOS/ContentInspect" "framework" "macos-arm64_x86_64"
install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/AgoraFaceCaptureExtension.xcframework" "AgoraRtcEngine_macOS/FaceCapture" "framework" "macos-arm64_x86_64"
install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/AgoraFaceDetectionExtension.xcframework" "AgoraRtcEngine_macOS/FaceDetection" "framework" "macos-arm64_x86_64"
install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/AgoraLipSyncExtension.xcframework" "AgoraRtcEngine_macOS/LipSync" "framework" "macos-arm64_x86_64"
install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/AgoraRtcKit.xcframework" "AgoraRtcEngine_macOS/RtcBasic" "framework" "macos-arm64_x86_64"
install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/Agorafdkaac.xcframework" "AgoraRtcEngine_macOS/RtcBasic" "framework" "macos-arm64_x86_64"
install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/Agoraffmpeg.xcframework" "AgoraRtcEngine_macOS/RtcBasic" "framework" "macos-arm64_x86_64"
install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/AgoraSoundTouch.xcframework" "AgoraRtcEngine_macOS/RtcBasic" "framework" "macos-arm64_x86_64"
install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/AgoraScreenCaptureExtension.xcframework" "AgoraRtcEngine_macOS/ScreenCapture" "framework" "macos-arm64_x86_64"
install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/AgoraSpatialAudioExtension.xcframework" "AgoraRtcEngine_macOS/SpatialAudio" "framework" "macos-arm64_x86_64"
install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/AgoraVideoQualityAnalyzerExtension.xcframework" "AgoraRtcEngine_macOS/VQA" "framework" "macos-arm64_x86_64"
install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/AgoraVideoAv1DecoderExtension.xcframework" "AgoraRtcEngine_macOS/VideoAv1CodecDec" "framework" "macos-arm64_x86_64"
install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/AgoraVideoAv1EncoderExtension.xcframework" "AgoraRtcEngine_macOS/VideoAv1CodecEnc" "framework" "macos-arm64_x86_64"
install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/AgoraVideoDecoderExtension.xcframework" "AgoraRtcEngine_macOS/VideoCodecDec" "framework" "macos-arm64_x86_64"
install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/video_dec.xcframework" "AgoraRtcEngine_macOS/VideoCodecDec" "framework" "macos-arm64_x86_64"
install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/AgoraVideoEncoderExtension.xcframework" "AgoraRtcEngine_macOS/VideoCodecEnc" "framework" "macos-arm64_x86_64"
install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/video_enc.xcframework" "AgoraRtcEngine_macOS/VideoCodecEnc" "framework" "macos-arm64_x86_64"
install_xcframework "${PODS_ROOT}/AgoraRtcEngine_macOS/AgoraVideoSegmentationExtension.xcframework" "AgoraRtcEngine_macOS/VirtualBackground" "framework" "macos-arm64_x86_64"

