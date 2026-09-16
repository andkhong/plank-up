// Real camera + real pose inference for the web harness.
//
// Mirrors the production architecture deliberately: inference runs here, next
// to the frames, and only landmarks cross into Dart. Pixels never do. On device
// this same boundary sits at the platform channel; here it sits at js_interop.
//
// The preview is NOT mirrored. The subject is a body seen side-on, not a face
// in a mirror, and flipping it would invert the spatial meaning of "hips up".

import {
  FilesetResolver,
  PoseLandmarker,
} from "https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.21";

const WASM =
  "https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.21/wasm";
const MODEL =
  "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/1/pose_landmarker_lite.task";

// BlazePose emits 33 points. These are the 15 our canonical schema uses, in
// the order the Dart Joint enum declares them. Everything else — the six hand
// points, the four foot points, the eyes and the mouth — is dropped here rather
// than shipped and ignored.
const CANONICAL = [0, 7, 8, 11, 12, 13, 14, 15, 16, 23, 24, 25, 26, 27, 28];

const state = {
  status: "idle", // idle | starting | running | error
  error: "",
  landmarker: null,
  video: null,
  latest: null,
  lastVideoTime: -1,
  width: 0,
  height: 0,
};

async function start() {
  if (state.status === "starting" || state.status === "running") return;
  state.status = "starting";
  state.error = "";

  try {
    const stream = await navigator.mediaDevices.getUserMedia({
      video: { width: { ideal: 960 }, height: { ideal: 540 } },
      audio: false,
    });

    const video = document.createElement("video");
    video.autoplay = true;
    video.playsInline = true;
    video.muted = true;
    video.srcObject = stream;
    // Kept out of the layout: Flutter paints the preview, not the DOM.
    video.style.position = "fixed";
    video.style.left = "-10000px";
    video.style.width = "320px";
    document.body.appendChild(video);
    await video.play();

    state.video = video;
    state.width = video.videoWidth;
    state.height = video.videoHeight;

    const vision = await FilesetResolver.forVisionTasks(WASM);
    state.landmarker = await PoseLandmarker.createFromOptions(vision, {
      baseOptions: { modelAssetPath: MODEL, delegate: "GPU" },
      runningMode: "VIDEO",
      numPoses: 1,
    });

    state.status = "running";
    requestAnimationFrame(loop);
  } catch (e) {
    state.status = "error";
    state.error = String(e && e.message ? e.message : e);
  }
}

function loop() {
  if (state.status !== "running") return;
  const video = state.video;

  if (video.currentTime !== state.lastVideoTime && video.videoWidth > 0) {
    state.lastVideoTime = video.currentTime;
    state.width = video.videoWidth;
    state.height = video.videoHeight;

    try {
      const result = state.landmarker.detectForVideo(video, performance.now());
      const poses = result.landmarks;
      if (poses && poses.length > 0) {
        const lm = poses[0];
        const flat = new Array(CANONICAL.length * 3);
        for (let i = 0; i < CANONICAL.length; i++) {
          const p = lm[CANONICAL[i]];
          flat[i * 3] = p.x;
          flat[i * 3 + 1] = p.y;
          // Older builds omit visibility; treat a missing score as confident
          // rather than as absent, so a schema change cannot silently blank
          // the whole body.
          flat[i * 3 + 2] =
            typeof p.visibility === "number" ? p.visibility : 1.0;
        }
        state.latest = flat;
      } else {
        state.latest = null;
      }
    } catch (e) {
      state.status = "error";
      state.error = String(e && e.message ? e.message : e);
      return;
    }
  }

  requestAnimationFrame(loop);
}

function stop() {
  state.status = "idle";
  state.latest = null;
  if (state.video && state.video.srcObject) {
    for (const track of state.video.srcObject.getTracks()) track.stop();
    state.video.remove();
  }
  state.video = null;
}

window.plankupPose = {
  start,
  stop,
  status: () => state.status,
  error: () => state.error,
  latest: () => state.latest,
  frameWidth: () => state.width,
  frameHeight: () => state.height,
};
