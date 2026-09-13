# commit-roulette

deal yourself a better commit hash with `groll`.

```text
[*] target  beef  |  prefix  |  unsigned
    ┌───────────────┐
    │  b  e  7  a   │
    └───────────────┘
[*] 420000 tries  |  8.20 mh/s  |  0.1s
[+] jackpot  beef83c2a194...
[*] undo: groll undo
```

supports ssh and gpg signing through your git settings

## play

```sh
groll beef # same as `groll roll beef`
groll cafe --suffix
groll dead --contains
groll commit beef -m "fix parser"
groll undo
```

## automatic rolls

requires git 2.54+

```sh
groll hooks install --global beef
groll hooks status
groll hooks uninstall --global
```

disable per repo: `git config --local hook.groll.enabled false`.
for older git or a hook manager, use `groll hooks run beef` in the existing post-commit hook

## build

requires zig 0.16.0 and git 2.48+. for signed commits you also need the selected signing tool

```sh
zig build -Doptimize=ReleaseFast
zig build release -j2
```

## notes

multithreaded mining uses hardware sha instructions (when available)  
for unsigned rolls it randomly varies a custom header & for signed rolls it varies signature armor
whitespace.
neither files, messages, nor dates change

hash kernels use public-domain [sha intrinsics](https://github.com/noloader/SHA-Intrinsics).
source attribution is in [vendor/sha/notice](vendor/sha/notice).
