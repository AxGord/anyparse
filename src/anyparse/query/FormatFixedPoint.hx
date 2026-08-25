package anyparse.query;

import haxe.Exception;

/**
 * `apq fmt`'s fixed-point round trip: format, then keep formatting the
 * writer's OWN output until it stops changing.
 *
 * `--list` and `--write` ask one question through one call —
 * `writeRoundTrip(source) == source` — so they cannot disagree WITHIN a run.
 * They disagreed ACROSS runs, and the reason is that the writer's output is
 * not always a fixed point: a wrap decision that reads the SOURCE line layout
 * gets a different answer once the writer has rewritten that layout, so
 * `--write` stopped one pass short of where its own `--list` would.
 *
 * Measured instance (2026-08-22). Set `wrapping.objectLiteral.defaultWrap` to
 * `fillLineWithLeadingBreak` on the Pony tree: one `fmt --write` rewrote 173
 * files and the very next `fmt --list` still reported 163 of them.
 * `HxObjectLit.fields` carries no `@:fmt(reflowSourceMultiline)`, so a
 * source-MULTILINE object literal is force-one-per-lined before the wrap
 * cascade is consulted at all — and pass 1's own leading break is what makes
 * the literal multiline. That is faithful to the fork
 * (`MarkWrapping.objectLiteralWrapping` returns early on
 * `!parsedCode.isOriginalSameLine`, and haxe-formatter 1.18.0 reproduces the
 * same two-pass convergence on the same file); what was NOT faithful is a
 * `--write` whose result its own `--list` rejects.
 *
 * It is a bug SHAPE, not one bug. Flipping each wrapping knob in turn on the
 * same 854-file corpus finds five more lists whose layout can be decided from
 * source newlines instead of from the cascade — `anonType` (33 files),
 * `callParameter` (2), `arrayWrap`, `anonFunctionSignature` and
 * `typeParameter` (one each). None of the 201 files needed more than
 * two rewrites, and none oscillated.
 *
 * ω-flat-source-fixed-point since closed that class at the wrap decision
 * itself: a cascade answer that BREAKS a source-flat list is emitted as
 * `OnePerLine` — the shape the force-multi path would force on the next pass
 * anyway — so pass 2 reproduces pass 1 by construction
 * (`WrapList.breakAsOnePerLine`). Measured over the whole Pony tree (867
 * files, its own `hxformat.json`): the three files that took two rewrites now
 * take one, and `fmt --write` writes a BYTE-IDENTICAL tree. The corpus stayed
 * at 775/126/43 with zero fixtures moved.
 *
 * So `fmt` writes the fixed point instead of one round trip. Two properties
 * make that safe rather than clever:
 *
 *  - It is FREE and byte-inert wherever it does not apply. A file already at
 *    its fixed point answers `source` on pass 1 and nothing else runs; a
 *    normally-dirty file confirms on pass 2. Every config this project ships
 *    is in that class — measured 0 files needing a second rewrite over `src`,
 *    `test`, and the whole Pony tree under its own `hxformat.json`. - It never SWALLOWS the defect it works around, PROVIDED the caller
 *    reports it. A file that never settles is a failure that leaves the bytes
 *    alone at every caller — churning a file forever is worse than declining
 *    to format it. A file that merely needed a SECOND rewrite is reported on
 *    stderr by `fmt` and by nobody else: `run` hands back `rewrites` and the
 *    three op-side callers below discard it, because `EditResult` /
 *    `NewFileResult` have nowhere to carry it. So a mutation op absorbs the
 *    writer defect silently today, which is the "permanent tax nobody can
 *    see" this bullet warns about, one caller short of closed. Plumbing
 *    `rewrites` out to the CLI boundary is the open work; a library must not
 *    own the diagnostic itself.
 *
 * `fmt` is no longer the only caller. `RefactorSupport.canonicalize` and
 * `NewFile.create` / `NewFile.createRaw` run the same loop over what they are
 * about to WRITE, because the gate the NEXT writer-emit op puts on that file is
 * `writeRoundTrip(s) == s` after ONE pass. A single round trip there reported
 * `wrote <file>` and left a file its own `fmt --list` immediately called
 * drifted, after which the next op refused it as non-canonical — measured on
 * Pony's `tools/src/module/Unpack.hx` through `apq add-member --reformat` and
 * through `apq new --raw -`. Seven files of that tree needed two rewrites when this landed (a count that
 * goes stale the moment the writer moves — the SHAPES are what is pinned);
 * `unit.WrapFlatSourceFixedPointTest` pins the three writer shapes behind them
 * and records what closing each would cost.
 *
 * Sister postcondition to `Patch.verbatimSpliceIntact`: an op-internal check
 * for a corruption class no tree-level gate can observe, because every gate
 * reads the same writer the defect lives in.
 */
@:nullSafety(Strict)
final class FormatFixedPoint {

	/**
	 * How many rewrites one file may take before `fmt` gives up. A correct
	 * writer needs exactly one, and since ω-flat-source-fixed-point every wrap
	 * cascade is one — the loop stays as the net that REPORTS a layout-reading
	 * decision rather than swallowing it.
	 * Four leaves room for a chain of nested layout-reading decisions settling
	 * one level per pass, and still bounds the work for a file that oscillates
	 * between two shapes instead of converging on either.
	 */
	public static inline final MAX_REWRITES: Int = 4;

	/**
	 * Round-trip `source` through `roundTrip` until the output stops changing.
	 *
	 * The parameter is the round-trip CLOSURE, not the plugin: the loop needs
	 * nothing else from a grammar, and a caller can hand it any `String ->
	 * Null<String>` — which is how the oscillating and mid-loop-throwing arms
	 * below are testable at all, neither being reachable through a real writer
	 * today.
	 *
	 * Pass 1 is the caller's own round trip and its exceptions PROPAGATE — a
	 * parse failure or a comment-loss refusal is the file's own, and the caller
	 * already reports it under the file's name. Every later pass reads the
	 * writer's own output instead, so a failure there is a WRITER defect and is
	 * captured into `failure`: the caller must not write, but it also must not
	 * blame the file.
	 */
	public static function run(roundTrip: (source:String) -> Null<String>, source: String): FormatFixedPointResult {
		final first: Null<String> = roundTrip(source);
		// `null` = no writer wired for this grammar; `first == source` = already
		// at the fixed point. Both answer without a second round trip, which is
		// what keeps a canonical tree — the gate's normal case — free.
		if (first == null || first == source) return {
			text: first,
			rewrites: 0,
			converged: true,
			failure: null
		};
		var prev: String = first;
		var rewrites: Int = 1;
		while (rewrites < MAX_REWRITES) {
			final next: Null<String> = try roundTrip(prev) catch (exception: Exception) {
				return {
					text: prev,
					rewrites: rewrites,
					converged: false,
					failure: 'rewrite ${rewrites + 1} could not re-format the writer output: ${exception.message}'
				};
			}
			if (next == null) return {
				text: prev,
				rewrites: rewrites,
				converged: false,
				failure: 'rewrite ${rewrites + 1} emitted nothing for the writer output'
			};
			if (next == prev) return {
				text: next,
				rewrites: rewrites,
				converged: true,
				failure: null
			};
			prev = next;
			rewrites++;
		}
		return {
			text: prev,
			rewrites: rewrites,
			converged: false,
			failure: 'no fixed point after $MAX_REWRITES rewrites — every pass changed the file again'
		};
	}

}

/**
 * Outcome of `FormatFixedPoint.run` — the fixed point plus what it cost to
 * reach it.
 */
@:nullSafety(Strict)
typedef FormatFixedPointResult = {

	/**
	 * The fixed point: the text every further round trip reproduces. `null`
	 * only when the grammar has no writer (the plugin's own `null` answer,
	 * forwarded unchanged). When `converged` is false this is the LAST output
	 * seen and no caller may write it.
	 */
	var text: Null<String>;

	/**
	 * How many round trips actually CHANGED their input. `0` = the file was
	 * already canonical, `1` = the healthy case (one rewrite, confirmed by a
	 * second round trip that changed nothing), `>1` = the writer read
	 * something its own output then altered.
	 */
	var rewrites: Int;

	/** A round trip reproduced its input, so `text` is a real fixed point. */
	var converged: Bool;

	/** Why no fixed point was reached; `null` whenever `converged` is true. */
	var failure: Null<String>;
};
