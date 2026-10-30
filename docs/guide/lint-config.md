# Lint configuration: `apqlint.json`

An `apqlint.json` is discovered by walking up from each linted file (per-file, directory-memoized — a `test/apqlint.json` governs the files beside and below it, and unlike a nested `hxformat.json` it EXTENDS the documents above rather than replacing the nearest one; see below) and configures that file's checks: per
rule it can disable the rule (`"enabled": false`, dropped from the default set — an
explicit `--rule` still runs it), override its reported severity (`"severity":
"error|warning|info"`, applied before `--fail-on` and the report), or set a
rule-specific option (e.g. complexity's `"max"`, which takes precedence over a
`checkstyle.json` threshold). A missing file is a no-op; a malformed one (invalid
JSON, or a wrong-typed top-level key — the file is read through a declared typed
schema) is skipped with one stderr line naming it, and the documents ABOVE it
still apply. Wrong-typed values INSIDE a rule's own options stay per-field lenient.

**A nested document EXTENDS the ones above it; it does not replace them.** The
whole chain from the linted file's directory to the filesystem root is folded,
nearest first, and a document overrides only the keys it names — per key at the
top level, per rule inside `rules`, and per key inside one rule entry, so
`{"oversized-type": {"maxMembers": 100}}` raises that threshold without
re-enabling a rule an ancestor disabled or dropping the options it set. ARRAYS
replace wholesale (there is no element-wise union, because a union has no way to
spell a removal), and every relative path — a `resolutionRoots` entry, the
`compilerOracle` hxml — resolves against the directory of the document that
DECLARED it, not the nested one. A document that wants to stand alone says
`"inherit": false`, which ends the chain at itself. The walk also STOPS at a project
root — the first ancestor directory holding a `.git` or a `haxelib.json`, that
directory's own document included. Without that bound any writable ancestor
(`/tmp`, `$HOME`) would join every project's config, and `compilerOracle` names an
hxml the oracle EXECUTES. A document that exists and cannot be READ is reported on
stderr rather than dropped, because the ancestor's answer would otherwise apply
silently to a question the project already answered. Discovery used to stop at the
first document and take it wholesale, which is silent in the worst way: a nested
file naming four relaxations inherited neither the resolution scope nor the
oracle nor the rules the root opted into, and a rule that is not in the set does
not fail — it finds nothing.

A top-level `"resolutionRoots"` (array of directory paths, relative to the
config file resolved to absolute) declares a separate RESOLUTION scope: the
`.hx` under those roots join the cross-file `SymbolIndex` that the type /
inheritance checks (`redundant-this`, `prefer-index-access`, `map-keys-lookup`),
the field-access checks (`prefer-final-field`, `prefer-final-public-field`,
`prefer-read-only-field` — a subtype declared in a root that WRITES an inherited
field vetoes the rewrite, exactly as a report-scope one does) and the REFLECTION
gates (`inline-constant`, `static-constant`, `prefer-enum-abstract`,
`orphan-accessor`, `unused-public-member` — each refuses its rewrite when a
`Reflect` / `Type.resolveClass` string anywhere in scope spells the name it would
erase) resolve against — so a class `extends openfl.display.Sprite` is seen to
inherit `addChild` even though OpenFL is not being linted. The resolution scope is
never reported and never edited by `--fix`; only the files named on the command
line are. The roots are read lazily — a run whose checks demand no cross-file
resolution never touches them.

A top-level `"resolutionLibs"` (array of haxelib NAMES) is the preferred form
for a library that is installed through haxelib: each name is resolved to that
library's actual source directory via `haxelib libpath <name>` (honouring a
`haxelib dev` link and the currently-selected version) and its `haxelib.json`
`classPath`, so the config stays correct on every machine regardless of whether
the library is a released version, a git install, or a dev link — no brittle
machine-specific path. Resolution is LAZY and happens inside the same
resolution-scope thunk: the `haxelib` lookup runs only when a check actually
demands the cross-file index (a `--rule prefer-single-quotes` run never spawns
`haxelib`), and a name that does not resolve (a typo / uninstalled lib) is
skipped with a stderr note while the lint proceeds. `resolutionLibs` and
`resolutionRoots` coexist and union into the same scope — reach for
`resolutionRoots` when the sources are a sibling checkout not registered with
haxelib OR the project's own tree, and `resolutionLibs` otherwise.

**A project's own sources are a legitimate root, and usually the important one.**
Nothing about the key says "library": it declares the RESOLUTION scope, while the
files named on the command line are the REPORT scope. Declare `["src", "test"]`
and a one-file `hxq lint src/pkg/A.hx` still resolves over the whole project.
That matters most to the reflection gates listed above, because their answer is
UNSAFE in one direction: with no roots there is no scope over the project's own
files, so the call answers "nothing in this project reflects that name" from the
one file it was handed, and `--fix` acts on it — erasing a name a sibling file
spells to `Reflect`, with the build still green. Declare the same paths the
project's own gate lints — a narrower root leaves the hole one directory smaller
— and declare them ONCE, in the outermost `apqlint.json`: a nested document
inherits the key, so a `test/apqlint.json` that says nothing about roots resolves
over the same project scope, with the paths still read relative to the ROOT
document's own directory. (Before the chain existed, discovery stopped at the
first document and took it wholesale, and a nested config without the key left
every file below it with no project scope at all.) The cost is one read+parse of the declared
tree per lint process, paid only when a check actually demands the index (a
`--rule prefer-single-quotes` run never touches it) and skipped for a report
scope that already contains the roots, since library entries dedupe against the
report paths before their sources are read. anyparse's own numbers, dated and
with the discriminating probe, are in its `docs/testing.md` § "The project
declares its own sources as `resolutionRoots`".

The installed Haxe **std** joins that same scope IMPLICITLY, with no key at all
— discovered through `HAXE_STD_PATH`, the `which haxe` sibling, or a known
install prefix, and contributed as its target-agnostic core (toplevel `*.hx`
plus `haxe/` and `sys/`). Whether `haxe.io.Bytes` resolves must not depend on
the project happening to declare an unrelated library, so a project with
NEITHER resolution key still gets it. That makes the resolution scope no longer
opt-in: a config-less run is inert only in the sense that it spawns no
`haxelib` and pays at most one memoised `which haxe` probe per process.

Decline the std with a top-level `"resolutionStd": false` (per project) or the
`APQ_NO_STD` environment variable, any value but empty or `0` (per process, and
it also cuts the std-derived inference tables). Reach for one of them when the
sources target a different Haxe version than the machine's — otherwise there is
no way to refuse, since discovery falls through to the known install prefixes
however `HAXE_STD_PATH` and `PATH` are set.

A top-level `"compilerOracle"` (a path to an `.hxml`, relative to the config
file resolved to absolute) opts the run into treating the Haxe compiler as
ground truth: `apq` runs `haxe <hxml> --no-output` and folds the verdict back
in — report mode prints a `compiler-confirmed` note on a clean build and FAILS
the run with the compiler's errors on a broken one, while `--fix` uses it to
verify each risky autofix and revert the ones that stop the project
typechecking. Every revert is NAMED — one `risky-fix REVERTED <file> (<rule>)`
line per rolled-back edit set, beside the summary's count — because a count
alone leaves a reader with a search: attributing three reverts over an 809-file
application once took an md5 snapshot of every file before and after a sweep
plus one run per candidate rule, and still missed two, since both came from
`OracleRelaxable` rules whose widened candidate set exists ONLY inside `--fix`
and which therefore report nothing at all in any report run. Without the key the
compiler is never spawned. The compile
directory is PROBED, because `haxe <path>` resolves an hxml's relative `-cp`
entries against the process cwd and real projects write them against two
different conventions: the hxml's relative classpaths are checked for existence
under the hxml's own directory and under the config's, and the candidate
resolving strictly more of them wins (a tie keeps the hxml's own directory). So
a config in a subdirectory naming a parent build file (`"../build.hxml"`, whose
`-cp src` lives next to the hxml) and a root config naming a lime-generated
`dist/<target>/haxe/debug.hxml` (whose `-cp src` is relative to the project
root the build is invoked from) both compile with the classpaths their authors
meant.

The key is also a LIST of configurations, because one hxml answers for one set of
defines and a `#if` has two or more arms: `[{"hxml": …, "defines": [ … ], "dir": …}]`
(`defines` and `dir` optional; the plain string is the one-element list). Each
risky edit is typechecked by EVERY configuration that compiles it and is kept only
when all of them confirm; an edit no configuration compiles is declined, not
guessed at. A configuration whose own build is red before any edit, or whose
compiled set cannot be probed, is EXCLUDED and named once per run, and the others
still judge what they cover. `defines` go ahead of `--each`, so every `--next` arm
of the hxml sees them. Full contract: `docs/testing.md` § "The oracle answers for
what it COMPILED, not for what you linted".

**What the member-reach analysis assumes.** With `reachConfigurationsComplete`
the member-reach analysis behind the loop rewrites reads the compilers' facts as
the truth, and it states two assumptions about the code no fact describes, one for
the project and the libraries alike. Target-language code — `__cpp__` / `__js__`,
`*.Syntax.code`, the code `@:functionCode` / `@:cppFileCode` / `@:headerClassCode` /
… paste, a native identifier — reaches only the values handed to it: its arguments
(`{0}` placeholders) and what its text names — a local or parameter by its name,
the object its method runs on by a spelling of `this` or the name of one of its
members (hxcpp reaches one unqualified), a static variable by its name beside its
class's or alone in its own class's code — and it makes an instance of a program
class only through the reflective producers its callers name. And it reaches a
member by a computed name, or runs a function with a receiver it is handed, only
inside the reflection whose call sites the facts record. The same assumption
decides what target code met on the way may do to the member a rewrite asks about:
its arguments include those of a call through a chain of names untyped code leaves
to the target (`untyped __global__.String(p, n)`), whose names count as its text,
and a value of a type the compiler represents itself and never null (`Int`,
`cpp.Char`) is no object. A site whose text names the member, or that reaches an
object carrying it — any object, once an object of that type may have left the type
system — answers nothing; any other site runs only the function values it is handed
and the members of the objects it is handed by their names. Target code whose text is
computed rather than a string literal leaves the analysis without an answer, and
so does a class value made from a name computed at run time (`Type.resolveClass(name)`)
— unless the project declares which classes such a name may make.

**`reflectiveClasses`** is that declaration, and like `reachConfigurationsComplete`
it is the project's responsibility: a list of globs over qualified type names
(`pack.sub.Name`; `*` within one dotted segment, `**` across segments, `?` and
`[…]` as in path globs). It names every class a class value may be of when the
facts cannot read the name it was made from: a name computed at run time and
handed to `Type.resolveClass`, a producer read as a value (`var f = Type.resolveClass`)
and a class declaring one read as a value — the project's code and the libraries'
alike, in every build it ships. A glob matches the class actually made, by its own
name: declaring `model.Node` declares none of its subtypes. A literal handed to a
producer directly still names its one class whatever the list says, and a
producer's body the compiler splices in (`Type.resolveClass` on js by default)
lost its name — which may have been such a literal — so it still leaves the
analysis without an answer. The reach analysis reads it only under `reachConfigurationsComplete`; without
the key such a name may name any class. A glob matching no class the builds typed
is reported once per run (`reflectiveClasses "<glob>" matches no class the builds
typed`): a misspelling, a class gone, or one no build compiles — which
`Type.resolveClass` cannot find there either. `thread-safety` reads the same list
under its own `closedWorld` instead (a run over the whole closed project): it bounds a
class type parameter by its instantiations only when no object of a class leaving it
free can be made from a computed name. A run whose linted paths declare
different lists, or some none, takes such a name to name any class.

```json
{ "reachConfigurationsComplete": true,
  "reflectiveClasses": ["model.nodes.*", "swf.exporters.animate.AnimateLibrary", "__ASSET__fonts_*"] }
```

**`reflectiveMethodHolders`** is the same kind of declaration for the other half of
reflection by a computed name: which classes' METHODS such a name may name — read
as function values, or written over. A method read by a name computed at run time (`Reflect.field(o, name)`,
`Reflect.getProperty`, any `Reflect`/`Type` member that may read a member's value)
is a value of no type, so a call of a value of any function type may run it; without
the key it may be any method of any object the read may be handed. With it, such a
read — and a reflective member or `Reflect`/`Type` itself read as a value, which
whatever calls it later hands a computed name — obtains a method only off an object
of a class one of the globs matches (or off such a class as a value, for a static).
Globs as in `reflectiveClasses`, matched against the class of the object read by its
own qualified name: declaring a class declares neither its subclasses nor its
superclass (where the facts cannot tell the two apart — an escaped instance of a
subclass counts as one of each class it extends — the answer stays the conservative
one). The same bound holds for what such an access RUNS: a method other than an
accessor runs off an object only when its class is declared (it runs that class's
methods and those it inherits), while `Reflect.getProperty`/`setProperty` still run the
getter or setter of an object of any class. The same bound holds for a WRITE by a
computed name (`Reflect.setField`/`setProperty` handed a name computed at run time, or
`Reflect` read as a value): it may replace a `dynamic` method only of an object of a
declared class, so a call of a `dynamic` method of any other class runs its declared
bodies and the values the facts see stored into it, by a typed write, by a write naming
it, or through its constructor's parameter (without the key, such a write may store
anything into any of them). It bounds methods only: a variable is read
whatever the list says, and a name a literal spells still names its one member. The project's responsibility, read only
under `reachConfigurationsComplete`, for the project's code and the libraries' alike;
list the classes whose methods code obtains — or whose `dynamic` methods it replaces —
by a name it computes: a callback dispatcher calling the handler objects it was handed
(lime's `JNI.onCallback`), a copy over `Type.getInstanceFields`, a decoder setting the
fields a payload names on an object of a class with a `dynamic` method — and no others: a read of parsed data, a structure or
a JSON value obtains no method, and neither does one over the names `Reflect.fields`
lists where that lists an instance's variables only (hxcpp, js). A glob
matching no class the builds typed is reported once per run, and a run whose linted
paths declare different lists, or some none, takes such a read to obtain any method. `thread-safety` reads the same list under its own `closedWorld`: it follows a parameter of a function into its calls (what a reflective write stores) only when no class the list names may lend that function. So an incomplete list now costs `thread-safety` RECALL as well: a class left out whose method a computed read does obtain is followed as if its every call were seen, and a lock handed to it that way is missed.

```json
{ "reflectiveMethodHolders": ["lime._internal.backend.native._NativeApplication.OrientationChangeListener",
    "ext.filedlg._FileSave.AndroidHandler", "openfl.filesystem.File"] }
```

**`ownedTypes`** declares which layer of the project OWNS a type or a member, for the
`owned-types` rule (inert without the key). Each entry names `types` (qualified type
paths, `pkg.Module.Sub` for a sub-type) and/or `members` (`pkg.Module.build`,
`pkg.Module.new` for construction), the `owners` that may reach them (globs over
qualified names as in `reflectiveClasses`, matched against the module a mention is
written in and the type declaration enclosing it; the declaring module always owns its
types), and `why` — quoted in every finding. An entry naming no owner, nothing owned
or no reason is dropped with a stderr line. Like every array of the chain, a nearer
`apqlint.json`'s list replaces an ancestor's. Semantics and limits:
`docs/cli-query-tool.md` § "`owned-types`".

```json
{ "ownedTypes": [
    { "types": ["anyparse.query.SymbolIndex.ImportInfo"],
      "owners": ["anyparse.query.TypeNameBinding", "anyparse.query.ImportBindings"],
      "why": "imports are read through the name-resolution layer" },
    { "members": ["anyparse.query.SymbolIndex.build"], "owners": ["anyparse.query.RefactorSupport"],
      "why": "the index host builds and memoises the index" } ] }
```

A top-level `"compilerOracleServer"` (boolean, default `false`) moves the
REPORT-mode oracle onto a WARM Haxe compilation server shared by every `apq`
process on the machine, instead of a fresh compile per run. The first lint
spawns a detached `haxe --wait <port>`, drives its initial compile, and records
the port and pid under the OS temp dir (`apq-oracle-<digest>.json`, keyed by the
hxml and its compile directory); every later lint typechecks through
`--connect`. The warm typecheck costs a small fraction of a cold compile, so the
oracle stops dominating a narrow lint; the very first call, which spawns the server
and drives its full compile, costs one run's worth of the cold path it then
replaces. It is opt-in because the server DELIBERATELY outlives the run
that started it — `APQ_NO_ORACLE_SERVER` (any value but empty or `0`) declines
it per process, and the recorded pid is how a daemon you no longer want gets
stopped. Every condition the warm path cannot decide under (nothing recorded, a
dead pid, no free port, or a port that answers as something other than a
compilation server) falls back to the cold compile, so the key changes what a
verdict COSTS, never what it is.

Two exclusions are deliberate. The `--fix` verification never uses that shared
server: a compilation server compares modification times at one-second
granularity, so a file written in the same second as the compile that read it
stays frozen at its previous content — exactly the question a post-write
verification asks. For the same reason every linted file modified since the last
compile is `server/invalidate`d before the typecheck, which leaves as a residual
only a file OUTSIDE the linted set written within that same second.

A `--fix` run given every rule starts servers of its OWN instead — one `haxe
--wait` per configuration, once the compiler-facts compiles are in, each
warming with a first compile in the background, all ended with the run (they
are jobs of the run's process driver, so they also die with a killed `apq`,
and each is TETHERED to that driver, so a SIGKILL of the process group `apq`
and the driver share takes them too; `OracleServerPool`, `SpawnJob.tethered`).
The `explicit-local-type` / `explicit-type` display server is such a job as well. Its plain typechecks — the risky fix's covering compile
and bisect probes, the oracle-assisted batch — go through them, and every path
the run may write whose TEXT moved since a server's last compile is
`server/invalidate`d first, so the one-second granularity cannot freeze a file.
Only a warm ACCEPTANCE is believed: a configuration a server rejects is
compiled again cold, its first one beside the warm compiles, because a server
can re-emit a stale null-safety diagnostic. The `-v` compiles (baselines,
coverage) stay cold; the risky phase of a full `--fix` run is what they shorten. `APQ_NO_ORACLE_SERVER`
declines these too, as does a machine whose compile budget cannot hold one
server per configuration.

```json
{ "resolutionLibs": ["openfl"] }
```

```json
{ "compilerOracle": "../build.hxml" }
```

```json
{ "compilerOracle": "build.hxml", "compilerOracleServer": true }
```

```json
{ "compilerOracle": [
	{ "hxml": "build.hxml" },
	{ "hxml": "build.hxml", "defines": ["android"] }
] }
```

```json
{ "resolutionStd": false }
```

```json
{ "resolutionRoots": ["../lib/openfl/src"],
  "rules": {
    "naming":                        { "severity": "error" },
    "complexity":                    { "max": 15 },
    "fold-adjacent-string-literals": { "enabled": false }
  } }
```
