# Guest Mode for Photos

Hand your iPhone over without handing over your library (iOS 16.5, RootHide).

A round button floats in the Photos app.

1. Tap it and choose up to 10 photos or videos. The button turns blue and shows how many.
2. Tap it again. After Face ID, Photos shows only those: a gallery of their own to swipe through,
   zoom and play. Nothing else can be scrolled to, shared, edited or deleted.
3. Tap it (now an amber lock) once more. After Face ID, Photos is back to normal.

Hold the button for a menu (change or clear the selection); drag it to move it. Guest Mode stays
on when Photos is closed and opened again. Settings > Guest Mode has the button's switch, size
and opacity.

Nothing in Photos is hooked: the tweak adds two windows of its own to the app (the button, and
the gallery that covers Photos while Guest Mode is on).

It covers the Photos app only. A guest who leaves Photos is outside it; Guided Access keeps
someone in one app.

## Building

GitHub Actions (`.github/workflows/build.yml`): a syntax check on Linux, the .deb with RootHide's
Theos on macOS, and a run inside the Photos app of an iOS 16.4 simulator (`tools/sim_test.sh`).
`tools/phone.sh` installs and inspects it on the phone over USB SSH.
