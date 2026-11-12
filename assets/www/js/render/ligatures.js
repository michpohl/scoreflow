// [ScoreFlow engine] Ligatures Layer — вынесено из index.html без изменений
// логики. Отрисовка музыкальных дуг ЭКРАННОЙ партитуры:
//   - Tie  -> VF.StaveTie между нотой и следующей того же голоса/высоты;
//   - Slur -> VF.Curve над диапазоном (маркеры slurStart/slurStop).
// Проход идёт ПОСЛЕ отрисовки всех нот (нужны финальные позиции). VF и ctx
// передаются параметрами (как и в остальном движке) — модуль не импортирует
// VexFlow. Печатный проход лиг (drawPrintTiesAndSlurs) принадлежит print-слою
// и остаётся в index.html. Зависимостей от render-слоя нет (цикла нет).
import { state } from '../utils/state.js';
import { voiceListOf, notationTies } from '../domain/notes.js';

// Рисует [fn] внутри того же горизонтального трансформа сжатия [tr],
// что и ноты такта (translate+scaleX). Иначе лига считалась бы по
// несжатым координатам и уезжала за пределы такта/строки. tr.sx==1 —
// трансформа нет (обычный такт), рисуем как есть.
function withTransform(ctx, tr, fn) {
    if (tr && tr.sx < 1 && ctx.openGroup) {
        ctx.openGroup('liga');
        const g = ctx.parent; // openGroup выставляет parent = новый <g>
        fn();
        ctx.closeGroup();
        if (g && g.setAttribute) {
            g.setAttribute('transform',
                'translate(' + tr.tx + ',0) scale(' + tr.sx + ',1)');
        }
    } else {
        fn();
    }
}

function sameTr(a, b) {
    return a && b && a.sx === b.sx && a.tx === b.tx;
}

// Лига длительности. Внутри одного такта — целая (в его трансформе).
// Соседние такты одной строки — целая (трансформ лишь если у обоих
// одинаковый). Через перенос строки — две частичные, КАЖДАЯ в трансформе
// своего такта (иначе хвост у сжатого такта уедет за край строки).
function drawTie(VF, ctx, a, mA, rowA, trA, b, mB, rowB, trB, first, last) {
    const full = function (tr) {
        withTransform(ctx, tr, function () {
            new VF.StaveTie({ first_note: a, last_note: b,
                first_indices: first, last_indices: last })
                .setContext(ctx).draw();
        });
    };
    try {
        if (mA === mB) {
            full(trA);
        } else if (rowA === rowB) {
            full(sameTr(trA, trB) ? trA : null);
        } else {
            withTransform(ctx, trA, function () {
                new VF.StaveTie({ first_note: a, last_note: null,
                    first_indices: first, last_indices: first })
                    .setContext(ctx).draw();
            });
            withTransform(ctx, trB, function () {
                new VF.StaveTie({ first_note: null, last_note: b,
                    first_indices: last, last_indices: last })
                    .setContext(ctx).draw();
            });
        }
    } catch (e) { console.error('tie draw failed:', e); }
}

function drawSlur(VF, ctx, a, mA, rowA, trA, b, mB, rowB, trB) {
    try {
        if (rowA === rowB) {
            const tr = (mA === mB) ? trA : (sameTr(trA, trB) ? trA : null);
            withTransform(ctx, tr, function () {
                new VF.Curve(a, b, {}).setContext(ctx).draw();
            });
        } else {
            // Через перенос строки — частичные дуги по сегментам
            // (best-effort), каждая в трансформе своего такта.
            try { withTransform(ctx, trA, function () {
                new VF.Curve(a, null, {}).setContext(ctx).draw(); }); }
            catch (e1) { /* нет правой границы — пропуск */ }
            try { withTransform(ctx, trB, function () {
                new VF.Curve(null, b, {}).setContext(ctx).draw(); }); }
            catch (e2) { /* нет левой границы — пропуск */ }
        }
    } catch (e) { console.error('slur draw failed:', e); }
}

// [geom] -> строка такта (row); [state.noteObjs]/[state.noteTransform] -> объект и
// трансформ сжатия ноты по noteId.
export function drawTiesAndSlurs(VF, ctx, score, geom) {
    const measures = score.measures || [];
    const voices = voiceListOf(score);
    const rowOf = function (mi) { return geom[mi] ? geom[mi].row : 0; };
    const idOf = function (mi, v, ni) { return mi + ':' + v + ':' + ni; };

    for (const { voiceId, from, to, pairs } of notationTies(score)) {
        const idA = idOf(from.mi, voiceId, from.ni);
        const idB = idOf(to.mi, voiceId, to.ni);
        const a = state.noteObjs[idA], b = state.noteObjs[idB];
        if (!a || !b) continue;
        drawTie(VF, ctx, a, from.mi, rowOf(from.mi), state.noteTransform[idA],
            b, to.mi, rowOf(to.mi), state.noteTransform[idB],
            pairs.map(([first]) => first), pairs.map(([, last]) => last));
    }

    // --- Slur: стек start/stop в пределах голоса по порядку ---
    for (let vi = 0; vi < voices.length; vi++) {
        const v = voices[vi];
        const stack = [];
        for (let mi = 0; mi < measures.length; mi++) {
            const notes = (measures[mi] && measures[mi][v]) || [];
            for (let ni = 0; ni < notes.length; ni++) {
                const n = notes[ni];
                if (!n) continue;
                if (n.slurStart) stack.push({ mi: mi, ni: ni });
                if (n.slurStop && stack.length > 0) {
                    const s = stack.pop();
                    const idA = idOf(s.mi, v, s.ni), idB = idOf(mi, v, ni);
                    const a = state.noteObjs[idA], b = state.noteObjs[idB];
                    if (a && b) drawSlur(VF, ctx, a, s.mi, rowOf(s.mi),
                        state.noteTransform[idA], b, mi, rowOf(mi), state.noteTransform[idB]);
                }
            }
        }
    }
}
