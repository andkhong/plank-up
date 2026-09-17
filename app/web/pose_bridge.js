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
  status: "idle", // idle | starting | running | ended | error
  error: "",
  source: "none", // none | camera | file
  landmarker: null,
  video: null,
  latest: null,
  lastVideoTime: -1,
  width: 0,
  height: 0,
  // Landmark stream captured while running, so a clip can be turned into a
  // replayable fixture instead of being watched once and lost.
  recording: [],
  recordingOn: false,
  startedAt: 0,
  label: "",
};

async function ensureLandmarker() {
  if (state.landmarker) return;
  const vision = await FilesetResolver.forVisionTasks(WASM);
  state.landmarker = await PoseLandmarker.createFromOptions(vision, {
    baseOptions: { modelAssetPath: MODEL, delegate: "GPU" },
    runningMode: "VIDEO",
    numPoses: 1,
  });
}

function makeVideo() {
  const video = document.createElement("video");
  video.autoplay = true;
  video.playsInline = true;
  video.muted = true;
  // Kept out of the layout: Flutter paints the overlay, not the DOM.
  video.style.position = "fixed";
  video.style.left = "-10000px";
  video.style.width = "320px";
  document.body.appendChild(video);
  return video;
}

async function start() {
  if (state.status === "starting" || state.status === "running") return;
  state.status = "starting";
  state.error = "";
  state.source = "camera";

  try {
    const stream = await navigator.mediaDevices.getUserMedia({
      video: { width: { ideal: 960 }, height: { ideal: 540 } },
      audio: false,
    });

    const video = makeVideo();
    video.srcObject = stream;
    await video.play();

    state.video = video;
    state.width = video.videoWidth;
    state.height = video.videoHeight;

    await ensureLandmarker();

    state.startedAt = performance.now();
    state.status = "running";
    requestAnimationFrame(loop);
  } catch (e) {
    state.status = "error";
    state.error = String(e && e.message ? e.message : e);
  }
}

/// Opens a file picker and runs the pipeline over the chosen clip.
///
/// Same detection path as the camera — only the frame source differs — so a
/// recorded plank or pushup exercises exactly the code a live one would, and
/// does it reproducibly.
async function startFile() {
  if (state.status === "starting") return;
  stop();
  state.status = "starting";
  state.error = "";
  state.source = "file";

  try {
    const file = await pickVideo();
    if (!file) {
      state.status = "idle";
      state.source = "none";
      return;
    }

    const video = makeVideo();
    video.loop = false;
    video.src = URL.createObjectURL(file);
    await video.play();

    state.video = video;
    state.label = file.name;
    state.width = video.videoWidth;
    state.height = video.videoHeight;

    video.addEventListener("ended", () => {
      if (state.status === "running") state.status = "ended";
    });

    await ensureLandmarker();

    state.startedAt = performance.now();
    state.status = "running";
    requestAnimationFrame(loop);
  } catch (e) {
    state.status = "error";
    state.error = String(e && e.message ? e.message : e);
  }
}

function pickVideo() {
  return new Promise((resolve) => {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = "video/*";
    input.style.display = "none";
    document.body.appendChild(input);
    input.addEventListener("change", () => {
      const file = input.files && input.files[0];
      input.remove();
      resolve(file || null);
    });
    // A cancelled picker fires no event on some browsers; the caller simply
    // stays idle rather than hanging on a promise that never settles.
    input.addEventListener("cancel", () => {
      input.remove();
      resolve(null);
    });
    input.click();
  });
}

function loop() {
  if (state.status !== "running") return;
  const video = state.video;

  if (video.currentTime !== state.lastVideoTime && video.videoWidth > 0) {
    state.lastVideoTime = video.currentTime;
    state.width = video.videoWidth;
    state.height = video.videoHeight;

    // MediaPipe requires strictly increasing timestamps. A file is driven by
    // its own clock so the whole clip is analysed at its recorded rate rather
    // than at whatever rate the browser happens to paint.
    const stamp =
      state.source === "file"
        ? video.currentTime * 1000
        : performance.now() - state.startedAt;

    try {
      const result = state.landmarker.detectForVideo(video, stamp);
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
        if (state.recordingOn) {
          state.recording.push({ t: Math.round(stamp), j: flat });
        }
      } else {
        state.latest = null;
        // An absent body is data too — a fixture that silently skips the
        // frames where detection failed cannot be used to measure detection.
        if (state.recordingOn) {
          state.recording.push({ t: Math.round(stamp), j: null });
        }
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
  state.source = "none";
  const video = state.video;
  if (video) {
    if (video.srcObject) {
      for (const track of video.srcObject.getTracks()) track.stop();
    }
    if (video.src) URL.revokeObjectURL(video.src);
    video.remove();
  }
  state.video = null;
}

function setRecording(on) {
  state.recordingOn = !!on;
  if (on) state.recording = [];
}

/// Serialises the captured stream as JSON Lines, the format the replay harness
/// reads. One frame per line so a truncated capture loses only its last line.
function exportFixture() {
  const lines = state.recording.map((f) => {
    const joints = {};
    if (f.j) {
      for (let i = 0; i < CANONICAL.length; i++) {
        joints[JOINT_NAMES[i]] = [
          round(f.j[i * 3]),
          round(f.j[i * 3 + 1]),
          round(f.j[i * 3 + 2]),
        ];
      }
    }
    return JSON.stringify({
      tMs: f.t,
      gravity: [0, 1],
      detection: f.j ? 0.9 : 0.05,
      persons: f.j ? 1 : 0,
      joints,
    });
  });
  return lines.join("\n");
}

function round(v) {
  return Math.round(v * 1e5) / 1e5;
}

/// Canonical joint order, matching Dart's `Joint.values`.
const JOINT_NAMES = [
  "nose",
  "leftEar",
  "rightEar",
  "leftShoulder",
  "rightShoulder",
  "leftElbow",
  "rightElbow",
  "leftWrist",
  "rightWrist",
  "leftHip",
  "rightHip",
  "leftKnee",
  "rightKnee",
  "leftAnkle",
  "rightAnkle",
];

function downloadFixture(name) {
  const blob = new Blob([exportFixture()], { type: "application/x-ndjson" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = (name || state.label || "capture").replace(/\.[^.]+$/, "") + ".jsonl";
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(a.href);
}

window.plankupPose = {
  start,
  startFile,
  stop,
  status: () => state.status,
  error: () => state.error,
  source: () => state.source,
  label: () => state.label,
  latest: () => state.latest,
  frameWidth: () => state.width,
  frameHeight: () => state.height,
  progress: () =>
    state.video && state.video.duration
      ? state.video.currentTime / state.video.duration
      : 0,
  setRecording,
  recordedFrames: () => state.recording.length,
  downloadFixture,
};
