# Asking the engine instead of inferring

`suites/test_wwapi` is a probe suite for the OpenMW 0.52 headless test
environment. It tests the **engine**, not WhyWalk: every assertion in it
replaces an inference that cost a round trip, and several that cost a week.

Copy it into the test environment and run it:

```sh
cp -r "00 Core/testenv/suites/test_wwapi" <testenv>/suites/
cd <testenv> && ./run_tests.sh suites/test_wwapi --verbose
```

It prints what it finds as well as asserting, and the printout is the point.

## What it answers, and what each question cost

| probe | what was inferred, and what it cost |
|---|---|
| `types.Creature.records` — a table? iterable? | Swept with `pairs`, found nothing, raised nothing. The strider lookup failed for two rounds and the vehicle could not animate. |
| `anim.BONE_GROUP` members, and an unknown key | `BONE_GROUP.Arms` **raised**, so `ridingAnim.lua` never loaded and nothing in the suite animated. |
| `I.UI.MODE` / `I.UI.WINDOW` — type, keys | `type(M) ~= 'table'` was always true, so travel interception stood down on every menu. Then `WINDOW.Travel` was declared absent on the same bad evidence. |
| `createRecordDraft` model path | Passed bare on a note saying the engine adds `meshes\`. It throws. Boarding a boat failed outright, nine times in one session. |
| two teleports in one frame | The journey teardown did exactly that, threw at its first statement, and left a second strider at the stop with the player stuck to it. |
| the yaw convention, and roll vs yaw | Probed in three modules with `rotateZ(0.5):getYaw() > 0`, which is self-consistent and tests nothing. |
| `playBlended` on a missing group | A silent no-op, which is correct behaviour and the reason three rounds of animation guesswork went unanswered. |
| `loops = -1` | Taken for "infinite". It is out of contract; the suite uses 999999. |

## What this environment cannot answer

No `.kf` and no real meshes, so animation **groups**, text keys and mesh
bounds are out of reach — which unfortunately includes the two questions
that have cost the most: which groups a given mesh carries, and which way a
mesh faces. Those need real data. The in-game diagnostics added on 31 October
(`vehicle animation:`) and 3 November (the mesh yaw offset) cover them
instead.
