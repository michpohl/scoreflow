import { BasicPitch, noteFramesToTime, outputToNotesPoly } from '@spotify/basic-pitch';
import * as tf from '@tensorflow/tfjs';
import { setWasmPaths } from '@tensorflow/tfjs-backend-wasm';

const sampleRate = 22050;
const assetDirectory = new URL('.', document.currentScript.src);
let modelPromise;
let transcribing = false;
// Older Android WebView builds can corrupt integer tensors on this WASM
// backend. WebGL is supported by the Android hardware-accelerated WebView.
let preferredBackend = /Android/i.test(navigator.userAgent) ? 'webgl' : 'wasm';

// The loopback server does not provide cross-origin isolation.
tf.env().set('WASM_HAS_MULTITHREAD_SUPPORT', false);
setWasmPaths(assetDirectory.href, true);

// tf.signal.frame in TFJS 3.21 omits the dtype when filling its final
// padded window. Match the CPU Fill kernel's float32 default on WASM.
const wasmFill = tf.getKernel('Fill', 'wasm');
tf.unregisterKernel('Fill', 'wasm');
tf.registerKernel({
  ...wasmFill,
  kernelFunc: parameters => wasmFill.kernelFunc({
    ...parameters,
    attrs: { ...parameters.attrs, dtype: parameters.attrs.dtype ?? 'float32' },
  }),
});

async function loadModel() {
  if (!await tf.setBackend(preferredBackend)) {
    await tf.setBackend('cpu');
  }
  return tf.loadGraphModel(new URL('model.json', assetDirectory).href);
}

function getModel() {
  modelPromise ??= loadModel().catch(error => {
    modelPromise = undefined;
    throw error;
  });
  return modelPromise;
}

async function collectActivations(samples, model) {
  const frames = [];
  const onsets = [];
  // Basic Pitch creates temporary tensors over several awaited calls.
  // Keep the model loaded, and release the inference tensors after each take.
  tf.engine().startScope();
  try {
    await new BasicPitch(model).evaluateModel(
      samples,
      (frameBatch, onsetBatch) => {
        frames.push(...frameBatch);
        onsets.push(...onsetBatch);
      },
      () => {},
    );
    return { frames, onsets };
  } finally {
    tf.engine().endScope();
  }
}

async function detect(samples) {
  let model;
  try {
    model = await getModel();
    return await collectActivations(samples, model);
  } catch (error) {
    if (tf.getBackend() === 'cpu') throw error;
    model?.dispose();
    modelPromise = undefined;
    preferredBackend = 'cpu';
    return collectActivations(samples, await getModel());
  }
}

function decodeSamples(pcmBase64) {
  const bytes = Uint8Array.from(atob(pcmBase64), byte => byte.charCodeAt(0));
  if (bytes.length % 2 !== 0) throw new Error('Incomplete PCM sample.');
  const pcm = new DataView(bytes.buffer);
  const samples = new Float32Array(bytes.length / 2);
  for (let index = 0; index < samples.length; index++) {
    samples[index] = pcm.getInt16(index * 2, true) / 32768;
  }
  return samples;
}

// Flutter supplies mono, little-endian PCM16 at Basic Pitch's native sample rate.
window.transcribePcm16 = async function transcribePcm16(pcmBase64) {
  if (transcribing) throw new Error('Transcription is already running.');
  const samples = decodeSamples(pcmBase64);
  if (samples.length < sampleRate / 10) return [];

  transcribing = true;
  try {
    const { frames, onsets } = await detect(samples);
    const duration = samples.length / sampleRate;
    // Require predicted onsets and a sustained frame response. Inferred
    // onsets and residual energy can add octave notes at model window joins.
    const notes = outputToNotesPoly(frames, onsets, .5, .35, 7, false, null, null, false);
    return noteFramesToTime(notes)
      .map(({ pitchMidi, startTimeSeconds, durationSeconds }) => ({
        midiNote: pitchMidi,
        startSeconds: Math.max(0, startTimeSeconds),
        endSeconds: Math.min(duration, startTimeSeconds + durationSeconds),
      }))
      .filter(note => note.endSeconds > note.startSeconds)
      .sort((first, second) =>
        first.startSeconds - second.startSeconds || first.midiNote - second.midiNote);
  } finally {
    transcribing = false;
  }
};
