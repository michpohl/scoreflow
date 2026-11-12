import { effectiveKeys, keySignatureAlterations } from './keysig.js';
import { parseKey, resolveMidi } from './pitch.js';

function sameKeys(a, b) {
    if (!a || !b || a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    return true;
}

// Each pair contains the source and destination notehead indices.
export function tiePitchPairs(from, to, fromMidis = from?.midis, toMidis = to?.midis) {
    if (!from || !to || from.rest || to.rest) return [];
    const a = from.keys || [];
    const b = to.keys || [];
    if (!Array.isArray(from.tiedPitchIndices)) {
        return from.tieToNext && sameKeys(a, b) ? a.map((_, i) => [i, i]) : [];
    }

    const used = new Set();
    const pairs = [];
    for (const i of from.tiedPitchIndices) {
        if (!Number.isInteger(i) || i < 0 || i >= a.length) continue;
        const pitch = parseKey(a[i]);
        const j = b.findIndex((key, index) => {
            if (used.has(index)) return false;
            if (!fromMidis?.length || !toMidis?.length) return key === a[i];
            const other = parseKey(key);
            return pitch.step === other.step && pitch.octave === other.octave &&
                fromMidis[i] === toMidis[index];
        });
        if (j < 0) continue;
        used.add(j);
        pairs.push([i, j]);
    }
    return pairs;
}

export function voiceListOf(score) {
    return score.instrument === 'drums' ? ['perc'] : ['treble', 'bass'];
}

// Share tie endpoints and accidental resolution between the screen and PDF.
export function* notationTies(score) {
    const measures = score.measures || [];
    const drums = score.instrument === 'drums';
    const keys = effectiveKeys(measures, score.keySignature);
    for (const voiceId of voiceListOf(score)) {
        const resolvePitches = !drums && measures.some(measure =>
            (measure?.[voiceId] || []).some(note => note.tiedPitchIndices?.length));
        let previous = null;
        for (let mi = 0; mi < measures.length; mi++) {
            const notes = measures[mi]?.[voiceId] || [];
            if (!notes.length && previous?.note.tiedPitchIndices?.length) previous = null;
            const keyAlt = resolvePitches ? keySignatureAlterations(keys[mi]) : null;
            const measureAcc = {};
            for (let ni = 0; ni < notes.length; ni++) {
                const note = notes[ni];
                const midis = !resolvePitches || note.rest
                    ? []
                    : (note.keys || []).map(key => resolveMidi(key, keyAlt, measureAcc));
                const current = { mi, ni, note, midis };
                if (previous) {
                    const pairs = tiePitchPairs(previous.note, note, previous.midis, midis);
                    if (pairs.length) yield { voiceId, from: previous, to: current, pairs };
                }
                previous = current;
            }
        }
    }
}
