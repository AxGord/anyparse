package anyparse.macro;

#if macro
import anyparse.macro.CodeSet.CodeRange;
import anyparse.macro.RegexScanPlan.AheadBranches;
import haxe.macro.Context;
import haxe.macro.Expr;

/**
 * Lowers a `RegexScanPlan` tree to the statements of one committed pass over `Input.charCodeAt`.
 *
 * The statements read and advance the local `_p` and run `fail` on a miss: `Input` answers -1 past either end, which
 * no set holds, so no bounds test is needed. Each `Repeat` and `Ahead` opens its own loop and hands its body a `fail`
 * that leaves that loop, so a `fail` never leaves a loop nested deeper than the one it was made for. A local takes its
 * construct's `depth` in its name, so a `fail` made outside never reads a local of the same name declared inside.
 */
final class TerminalScanLowering {

	/**
	 * A block running `then` after the pass, with `_in` the input, `_hit` whether `tree` matched at `start` and `_p`
	 * past the match when it did.
	 */
	public static function scan(tree: ScanNode, input: Expr, start: Expr, then: Expr): Expr {
		final body: Array<Expr> = steps(tree, macro break, 0);
		body.push(macro _hit = true);
		return macro {
			final _in: anyparse.runtime.Input = $input;
			var _p: Int = $start;
			var _hit: Bool = false;
			do
				$b{body} while (false);
			$then;
		};
	}

	private static function steps(node: ScanNode, fail: Expr, depth: Int): Array<Expr> {
		return switch node {
			case Chars(set): [charsStep(set, fail, depth)];
			case Seq(items): [for (item in items) for (step in steps(item, fail, depth)) step];
			case Alt(branches): [altStep(branches, fail, depth)];
			case Repeat(body, min, many):
				final out: Array<Expr> = min > 0 ? steps(body, fail, depth) : [];
				out.push(many ? loopStep(body, depth) : optionalStep(body, depth));
				out;
			case Ahead(body, negative): [aheadStep(body, negative, fail, depth)];
			case WordBoundary:
				final before: Expr = isWord(macro _in.charCodeAt(_p - 1));
				final after: Expr = isWord(macro _in.charCodeAt(_p));
				[macro if ($before == $after) $fail];
		};
	}

	private static function charsStep(set: CodeSet, fail: Expr, depth: Int): Expr {
		final name: String = '_c$depth';
		final holds: Expr = setTest(macro $i{name}, set);
		return macro {
			final $name: Int = _in.charCodeAt(_p);
			if (!($holds)) $fail;
			_p++;
		};
	}

	/** The branches begin with disjoint sets, so the next code unit picks the one branch that can match. */
	private static function altStep(branches: Array<ScanNode>, fail: Expr, depth: Int): Expr {
		final name: String = '_c$depth';
		var chain: Expr = fail;
		var i: Int = branches.length;
		while (--i >= 0) {
			final holds: Expr = setTest(macro $i{name}, RegexScanPlan.firstOf(branches[i]));
			final picked: Array<Expr> = steps(branches[i], fail, depth + 1);
			chain = macro if ($holds)
				$b{picked}
			else
				$chain;
		}
		return macro {
			final $name: Int = _in.charCodeAt(_p);
			$chain;
		};
	}

	private static function loopStep(body: ScanNode, depth: Int): Expr {
		return switch body {
			case Chars(set):
				final name: String = '_c$depth';
				final holds: Expr = setTest(macro $i{name}, set);
				macro while (true) {
					final $name: Int = _in.charCodeAt(_p);
					if (!($holds)) break;
					_p++;
				};
			case _:
				final saved: String = '_s$depth';
				final inner: Array<Expr> = steps(
					body, macro {
						_p = $i{saved};
						break;
					},
					depth + 1
				);
				macro while (true) {
					final $saved: Int = _p;
					$b{inner};
				};
		};
	}

	private static function optionalStep(body: ScanNode, depth: Int): Expr {
		final saved: String = '_s$depth';
		final inner: Array<Expr> = steps(
			body, macro {
				_p = $i{saved};
				break;
			},
			depth + 1
		);
		return macro {
			final $saved: Int = _p;
			do
				$b{inner} while (false);
		};
	}

	/**
	 * Whether any path of `body` matches here; the cursor is left where it was. Order does not change that answer, so
	 * the branches that can only begin with one code unit are tried under a switch on it.
	 */
	private static function aheadStep(body: ScanNode, negative: Bool, fail: Expr, depth: Int): Expr {
		final saved: String = '_s$depth';
		final found: String = '_f$depth';
		final head: String = '_h$depth';
		final tries: Array<Expr> = [];
		final split: Null<AheadBranches> = RegexScanPlan.headAlternation(body);
		if (split == null) {
			tries.push(attempt(steps(body, macro break, depth + 1), found));
		} else {
			final byCode: Map<Int, Array<Expr>> = [];
			final codes: Array<Int> = [];
			final anyHead: Array<Expr> = [];
			for (branch in split.branches) {
				final path: ScanNode = Seq([branch].concat(split.tail));
				final attempted: Expr = attempt(steps(path, macro break, depth + 1), found);
				final tried: Expr = macro if (!$i{found}) {
					_p = $i{saved};
					$attempted;
				};
				final code: Int = RegexScanPlan.nullable(path) ? -1 : RegexScanPlan.firstOf(path).soleCode();
				final group: Null<Array<Expr>> = byCode[code];
				if (code < 0) {
					anyHead.push(tried);
				} else if (group == null) {
					byCode[code] = [tried];
					codes.push(code);
				} else {
					group.push(tried);
				}
			}
			final cases: Array<Case> = [
				for (code in codes) { values: [macro $v{code}], expr: macro $b{byCode[code] ?? []} }
			];
			tries.push(macro final $head: Int = _in.charCodeAt(_p));
			tries.push({ expr: ESwitch(macro $i{head}, cases, macro {}), pos: Context.currentPos() });
			for (tried in anyHead) tries.push(tried);
		}
		final verdict: Expr = negative ? macro $i{found} : macro !$i{found};
		return macro {
			final $saved: Int = _p;
			var $found: Bool = false;
			$b{tries};
			_p = $i{saved};
			if ($verdict) $fail;
		};
	}

	private static function attempt(path: Array<Expr>, found: String): Expr {
		final all: Array<Expr> = path.concat([macro $i{found} = true]);
		return macro do
			$b{all} while (false);
	}

	private static function isWord(code: Expr): Expr {
		return setTest(code, RegexScanReader.wordSet());
	}

	/**
	 * Whether `code`, a read of `Input.charCodeAt`, is in `set`. A set spelled by what it leaves out has to refuse
	 * the -1 that means past the input by itself.
	 */
	private static function setTest(code: Expr, set: CodeSet): Expr {
		final without: CodeSet = set.complement();
		if (without.ranges.length >= set.ranges.length) return anyOf(code, set.ranges);
		var test: Expr = macro $code >= 0;
		for (range in without.ranges) {
			final outside: Expr = range.lo == range.hi ? macro $code != $v{range.lo} : macro $code < $v{range.lo} || $code > $v{range.hi};
			test = macro $test && ($outside);
		}
		return test;
	}

	private static function anyOf(code: Expr, ranges: Array<CodeRange>): Expr {
		if (ranges.length == 0) return macro false;
		var test: Expr = rangeTest(code, ranges[ranges.length - 1]);
		var i: Int = ranges.length - 1;
		while (--i >= 0) {
			final term: Expr = rangeTest(code, ranges[i]);
			test = macro $term || $test;
		}
		return test;
	}

	private static function rangeTest(code: Expr, range: CodeRange): Expr {
		if (range.lo == range.hi) return macro $code == $v{range.lo};
		if (range.hi == CodeSet.MAX_CODE) return macro $code >= $v{range.lo};
		return macro $code >= $v{range.lo} && $code <= $v{range.hi};
	}

}
#end
