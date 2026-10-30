# Getting started

Installing `hxq` / `apq` and a first query and rewrite. Every flag of a command: `hxq <command> --help`.

## Install and build

Requires [Haxe](https://haxe.org) 4.x and Node.js (for the JS-based CLI).

```sh
git clone https://github.com/AxGord/anyparse
cd anyparse
haxe bin/apq-js.hxml          # builds bin/apq.js — the query/refactor CLI
```

`bin/hxq` is a thin launcher that runs `apq` with the Haxe grammar preselected. Put it
on your `PATH` for a global `hxq`:

```sh
ln -s "$PWD/bin/hxq" ~/.local/bin/hxq
```

After that, `hxq <cmd> …` == `node bin/apq.js <cmd> --lang haxe …`. The launcher
auto-rebuilds the shared `bin/apq.js` when `src/` changes, but only when run from inside this
repository's main tree; from any other directory a stale engine runs with a one-line warning
(rebuild with `haxe bin/apq-js.hxml` or pin `HXQ_BIN`). `HXQ_SHARED_REBUILD=0` disables the
shared rebuild everywhere.

## Quickstart

Given `Sample.hx`:

```haxe
class Sample {
	public function area(width:Int, height:Int):Int {
		final total = width * height;
		return total;
	}
}
```

**Find by structure, not regex.** Match every multiplication, every `return`, or a
declaration by name:

```sh
$ hxq search '$a * $b' Sample.hx
Sample.hx:
  3:16: match (a=width, b=height)

$ hxq ast Sample.hx --select 'FnMember:area'
(FnMember
  area
  (Required width)
  (Required height)
  (Named Int)
  (BlockBody
    (FinalStmt total (Mul (IdentExpr width) (IdentExpr height)))
    (ReturnStmt (IdentExpr total))))
```

**Resolve a symbol with scope awareness** — declarations, reads and writes, each
pointing back at its binding:

```sh
$ hxq refs total Sample.hx
Sample.hx:
  3:2: [decl] total
  4:9: [read] total -> 3:2
```

**Refactor at the AST level.** Operations take a `<line>:<col>` cursor (the exact
coordinate `refs` prints), print the rewrite to stdout, and apply in place with
`--write`. Everything but the touched span stays byte-identical, and a result that does
not re-parse is rejected rather than written.

```sh
$ hxq rename Sample.hx 3:8 prod          # rename the binding at the cursor + its uses
class Sample {
	public function area(width:Int, height:Int):Int {
		final prod = width * height;
		return prod;
	}
}

$ hxq inline Sample.hx 3:8               # inline the local into its single use
class Sample {
	public function area(width:Int, height:Int):Int {
		return (width * height);
	}
}

$ hxq change-sig Sample.hx 2:18 1,0      # reorder params (+ resolvable call sites)
class Sample {
	public function area(height:Int, width:Int):Int {
		final total = width * height;
		return total;
	}
}
```

Every query and most refactors accept `--json` for machine-readable output — the
combination of stable line:col coordinates, JSON, and re-parse validation is what makes
these operations safe to drive from scripts or coding agents.

For the full flag set on any command: `hxq <cmd> --help`.
