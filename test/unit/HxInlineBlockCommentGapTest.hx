package unit;

import utest.Assert;
import utest.Test;
import anyparse.format.comment.CommentInventory;
import anyparse.format.comment.CommentLossException;
import anyparse.grammar.haxe.HaxeQueryPlugin;

using StringTools;

/**
 * The inline-block-comment seam inventory: which expression positions the
 * Trivia parser CAPTURES, and which ones have no slot and therefore fall to
 * the `writeRoundTrip` comment guard.
 *
 * Both halves are pinned deliberately. `CAPTURED` shapes prove the guard is
 * not over-eager — a comment the writer legitimately re-emits (possibly on
 * its own line) must not freeze the file. `SLOT_LESS` shapes are the open
 * defect list: the parser drops the comment, so the round trip refuses. When
 * a future slice teaches one of them a capture slot, its entry moves up to
 * `CAPTURED` and this test says so.
 */
class HxInlineBlockCommentGapTest extends Test {

	/** Seams the Trivia parser captures — the round trip keeps the comment. */
	private static final CAPTURED: Array<Array<String>> = [
		['assign_trail', 'x = 2 /* t */;'],
		['assign_rhs_lead', 'x = /* rh */ 2;'],
		['assign_op', 'x += /* o */ 1;'],
		['var_init_trail', 'var x = 5 /* i */;'],
		['return_trail', 'return x /* r */;'],
		['stmt_lead', '/* s */ run();'],
		['callarg_lead', 'f(/* a */ x);'],
		['callarg_second', 'f(x, /* a */ y);'],
		['callarg_trail', 'f(x /* a */);'],
		['call_noargs', 'f(/* none */);'],
		['nested_call', 'f(g(/* n */ x));'],
		['new_arg', 'var v = new Foo(/* n */ 1);'],
		['binop_rhs_lead', 'var v = a + /* m */ b;'],
		['string_concat', "var s = 'a' + /* c */ 'b';"],
		['array_elem', 'var a = [/* e */ 1, 2];'],
		['array_elem2', 'var a = [1, /* e */ 2];'],
		['bracket_key', 'var m = [/* k */ 1 => 2];'],
		['array_compr', 'var a = [for (i in 0...3) /* c */ i];'],
		['ifexpr_assign', 'var v = if (c) /* a */ 1 else 2;'],
		['case_body', 'switch (v) {\n\t\t\tcase 1:\n\t\t\t\t/* c */ run();\n\t\t}'],
		[
			'try_catch',
			'try {\n\t\t\trun();\n\t\t} catch (e: Dynamic) {\n\t\t\t/* c */ run();\n\t\t}'
		],
		[
			'if_else_stmt',
			'if (c) {\n\t\t\trun();\n\t\t} else /* e */ {\n\t\t\trun();\n\t\t}'
		],
		// ω-before-trail: the gap between a mandatory `@:trail` Ref field's
		// last token and its own close literal. Five constructs share that
		// one slot, which is why they arrived together.
		['if_cond_trail', 'if (x /* c */) {\n\t\t\trun();\n\t\t}'],
		[
			'switch_subj_trail',
			'switch (v /* s */) {\n\t\t\tcase 1:\n\t\t\t\trun();\n\t\t}'
		],
		['while_cond_trail', 'while (c /* w */) {\n\t\t\trun();\n\t\t}'],
		['do_while_trail', 'do {\n\t\t\trun();\n\t\t} while (c /* d */);'],
		[
			'catch_param_trail',
			'try {\n\t\t\trun();\n\t\t} catch (e: Dynamic /* c */) {\n\t\t\trun();\n\t\t}'
		],
	];

	/** Seams with no capture slot — the parser drops the comment, so the round trip refuses. */
	private static final SLOT_LESS: Array<Array<String>> = [
		['cond_if', 'if (/* c */ x) {\n\t\t\trun();\n\t\t}'],
		['while_cond', 'while (/* w */ c) {\n\t\t\trun();\n\t\t}'],
		['do_while', 'do {\n\t\t\trun();\n\t\t} while (/* d */ c);'],
		['for_iter', 'for (i in /* f */ list) {\n\t\t\trun();\n\t\t}'],
		['switch_subj', 'switch (/* s */ v) {\n\t\t\tcase 1:\n\t\t\t\trun();\n\t\t}'],
		['case_pat', 'switch (v) {\n\t\t\tcase /* c */ 1:\n\t\t\t\trun();\n\t\t}'],
		[
			'catch_type',
			'try {\n\t\t\trun();\n\t\t} catch (/* c */ e: Dynamic) {\n\t\t\trun();\n\t\t}'
		],
		['return_lead', 'return /* r */ x;'],
		['return_void', 'return /* v */;'],
		['throw_lead', 'throw /* t */ e;'],
		['throw_trail', 'throw e /* t */;'],
		['break_trail', 'while (c) {\n\t\t\tbreak /* b */;\n\t\t}'],
		['var_init', 'var x = /* i */ 5;'],
		['multi_var', 'var a = 1, b = /* m */ 2;'],
		['paren_lead', 'var v = (/* c */ x);'],
		['paren_trail', 'var v = (x /* c */);'],
		['binop_lhs_lead', 'var v = /* m */ a + b;'],
		['ternary_cond', 'var v = /* q */ c ? a : b;'],
		['ternary_then', 'var v = c ? /* q */ a : b;'],
		['ternary_else', 'var v = c ? a : /* q */ b;'],
		['unary_lead', 'var v = !/* u */ x;'],
		['field_access', 'var v = x./* d */ y;'],
		['index_lead', 'var v = a[/* ix */ 0];'],
		['obj_field', 'var o = { a: /* o */ 1 };'],
		['cast_lead', 'var v = cast(/* c */ x, Int);'],
		['arrow_body', 'var f = () -> /* b */ 1;'],
		['untyped_lead', 'var v = untyped /* u */ x;'],
		['macro_lead', 'var v = macro /* m */ x;'],
	];

	/** Slot-less seams outside a function body — same contract, other hosts. */
	private static final SLOT_LESS_DECLS: Array<Array<String>> = [
		['field_init', 'class Foo {\n\tvar x: Int = /* f */ 1;\n}\n'],
		['typeparam', 'class Foo {\n\tvar x: Array</* t */ Int>;\n}\n'],
		['meta_arg', 'class Foo {\n\t@:meta(/* m */ 1) var x: Int;\n}\n'],
		['return_type', 'class Foo {\n\tfunction bar(): /* r */ Void {}\n}\n'],
		['extends_lead', 'class Foo extends /* e */ Bar {}\n'],
		['enum_ctor_arg', 'enum Foo {\n\tA(/* c */ x: Int);\n}\n'],
		['anon_field', 'typedef T = {\n\ta: /* a */ Int,\n}\n'],
	];

	/**
	 * The guard's escape hatch is process-wide, so a developer running the
	 * suite with `APQ_ALLOW_COMMENT_LOSS` set would otherwise see every
	 * refusal assertion fail. Neutralised per test, restored after.
	 */
	private var _savedDecline: Null<String> = null;

	public inline function teardown(): Void Sys.putEnv(CommentInventory.DECLINE_ENV, _savedDecline);

	public function setup(): Void {
		_savedDecline = Sys.getEnv(CommentInventory.DECLINE_ENV);
		Sys.putEnv(CommentInventory.DECLINE_ENV, '');
	}

	public function testCapturedSeamsRoundTripWithTheirComment(): Void {
		for (entry in CAPTURED) {
			final source: String = inBody(entry[1]);
			final written: Null<String> = try new HaxeQueryPlugin().writeRoundTrip(source) catch (exception: CommentLossException) {
				Assert.fail('${entry[0]}: writer lost a captured comment (${exception.comment})');
				continue;
			}
			Assert.isNull(CommentInventory.firstMissing(source, written ?? ''), '${entry[0]}: comment missing from output');
			// Second, INDEPENDENT oracle: the comment's own text has to be in
			// the emitted bytes. `firstMissing` is the guard's own check, so on
			// its own this loop would pass if that check ever regressed to
			// always-null. Body text (not the delimiters) because one seam
			// legally re-emits its block comment as a line comment.
			Assert.stringContains(commentBody(entry[1]), written ?? '', '${entry[0]}: comment text missing from output');
		}
	}

	public function testSlotLessSeamsRefuseRatherThanDropTheComment(): Void {
		for (entry in SLOT_LESS) assertRefused(entry[0], inBody(entry[1]));
	}

	public function testSlotLessDeclSeamsRefuseRatherThanDropTheComment(): Void {
		for (entry in SLOT_LESS_DECLS) assertRefused(entry[0], entry[1]);
	}

	private function assertRefused(name: String, source: String): Void {
		try {
			final written: Null<String> = new HaxeQueryPlugin().writeRoundTrip(source);
			Assert.fail('$name: expected a comment-loss refusal, got: $written');
		} catch (exception: CommentLossException)
			Assert.pass();
	}

	private function inBody(statements: String): String return 'class Foo {\n\tfunction bar() {\n\t\t$statements\n\t}\n}\n';

	/** The text between a fixture's `/*` and `*\/`, trimmed. */
	private function commentBody(fixture: String): String {
		final open: Int = fixture.indexOf('/*');
		final close: Int = fixture.indexOf('*/', open);
		return fixture.substring(open + 2, close).trim();
	}

}
