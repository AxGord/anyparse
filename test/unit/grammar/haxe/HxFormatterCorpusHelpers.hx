package unit.grammar.haxe;

#if (sys || nodejs)
import sys.FileSystem;
import sys.io.File;
#end

/**
 * One parsed `.hxtest` golden file — three sections separated by
 * `\n---\n` in the on-disk format used by the AxGord/haxe-formatter
 * fork's test corpus. `config` is the per-case `hxformat.json` string,
 * `input` is the pre-format Haxe source, `expected` is the reference
 * formatter's byte-exact output.
 */
typedef HxTestCase = {
	final config: String;
	final input: String;
	final expected: String;
}

/**
 * Shared helpers for the haxe-formatter corpus harness. Resolves the
 * fork root from the `ANYPARSE_HXFORMAT_FORK` environment variable and
 * parses individual `.hxtest` golden files into `HxTestCase` triples.
 * The fork lives outside the project tree, so the path is
 * configuration, not a hard-coded constant — a missing fork yields
 * `null` and the consuming test skips cleanly.
 */
@:nullSafety(Strict)
final class HxFormatterCorpusHelpers {

	/**
	 * The one answer to "which corpus fixtures encode an authorial layout the canonical writer does not reproduce":
	 * each expected section is a layout the fork read from its input (an explicit `keep`, or the fork's `keep`
	 * default for `expressionCase` / `comprehensionFor`), and the writer's output is a function of the AST and the
	 * options alone. Such a fixture failing is not a defect; one that passes no longer belongs here.
	 */
	public static final FORK_AUTHORIAL: Array<String> = [
		'test/testcases/emptylines/getter_setter_keep.hxtest',
		'test/testcases/indentation/else_in_return_switch_with_expressionIf_same.hxtest',
		'test/testcases/indentation/issue_114_untyped_keep.hxtest',
		'test/testcases/indentation/issue_144_switch_braceless_if.hxtest',
		'test/testcases/indentation/issue_168_object_literal_in_array_comprehension.hxtest',
		'test/testcases/indentation/issue_258_object_literal_false.hxtest',
		'test/testcases/indentation/issue_258_object_literal_true.hxtest',
		'test/testcases/indentation/issue_304_expression_if_indentation_keep_indent_assignment_expr.hxtest',
		'test/testcases/indentation/issue_304_expression_if_indentation_keep.hxtest',
		'test/testcases/indentation/issue_334_complex_var_assignment_indent_value_expr.hxtest',
		'test/testcases/indentation/issue_334_complex_var_assignment.hxtest',
		'test/testcases/indentation/lambda_map.hxtest',
		'test/testcases/lineends/issue_231_anon_function_parameter_keep.hxtest',
		'test/testcases/lineends/issue_329_else_body_with_popen_indent_value_expr_keep.hxtest',
		'test/testcases/lineends/issue_329_else_body_with_popen_keep.hxtest',
		'test/testcases/other/for_with_macro_reification.hxtest',
		'test/testcases/other/issue_34_switch_this.hxtest',
		'test/testcases/sameline/issue_120_expression_case_2_keep.hxtest',
		'test/testcases/sameline/issue_121_longer_expression_case_keep.hxtest',
		'test/testcases/sameline/issue_125_expression_case_and_comment_keep.hxtest',
		'test/testcases/sameline/issue_132_expression_case_if.hxtest',
		'test/testcases/sameline/issue_137_array_comprehension.hxtest',
		'test/testcases/sameline/issue_235_keep_if_else.hxtest',
		'test/testcases/sameline/issue_254_case_colon_keep.hxtest',
		'test/testcases/sameline/issue_257_return_keep.hxtest',
		'test/testcases/sameline/issue_257_return_next.hxtest',
		'test/testcases/sameline/issue_257_return_same_indent_value_expr.hxtest',
		'test/testcases/sameline/issue_257_return_same.hxtest',
		'test/testcases/sameline/issue_303_return_sameline_all_keep.hxtest',
		'test/testcases/sameline/issue_306_case_bropen_keep_curly_both.hxtest',
		'test/testcases/sameline/issue_306_case_bropen_keep.hxtest',
		'test/testcases/sameline/issue_362_untyped_body_keep.hxtest',
		'test/testcases/sameline/issue_552_non_value_if_in_switch.hxtest',
		'test/testcases/sameline/return_if_else_if_keep.hxtest',
		'test/testcases/sameline/switch_case_keep.hxtest',
		'test/testcases/wrapping/else_after_switch_as_if_body.hxtest',
		'test/testcases/wrapping/expression_paren_close_multiline.hxtest',
		'test/testcases/wrapping/issue_238_keep_wrapping_array_comprehension.hxtest',
		'test/testcases/wrapping/issue_238_keep_wrapping_array.hxtest',
		'test/testcases/wrapping/issue_238_keep_wrapping_call.hxtest',
		'test/testcases/wrapping/issue_238_keep_wrapping_function_signature.hxtest',
		'test/testcases/wrapping/issue_238_keep_wrapping_nowrap.hxtest',
		'test/testcases/wrapping/issue_238_keep_wrapping_object_literal.hxtest',
		'test/testcases/wrapping/issue_238_keep_wrapping_return_call.hxtest',
		'test/testcases/wrapping/issue_238_keep_wrapping.hxtest',
		'test/testcases/wrapping/issue_299_opboolchain_keep.hxtest',
		'test/testcases/wrapping/issue_311_line_break_before_popen_keep.hxtest',
		'test/testcases/wrapping/issue_355_var_wrapping_keep.hxtest',
		'test/testcases/wrapping/issue_357_array_comprehension.hxtest',
		'test/testcases/wrapping/method_chain_with_comments_keep.hxtest',
		'test/testcases/wrapping/opadd_chain_keep.hxtest',
		'test/testcases/wrapping/wrapping_method_chain_keep.hxtest',
		'test/testcases/wrapping/wrapping_of_function_signature_keep.hxtest'
	];

	private static inline final ENV_KEY: String = 'ANYPARSE_HXFORMAT_FORK';
	private static inline final SECTION_SEP: String = '\n---\n';
	private static inline final EXPECTED_SECTIONS: Int = 3;

	private function new(): Void {}

	/**
	 * Returns the absolute path to the haxe-formatter fork root, or
	 * `null` if the environment variable is unset, empty, points at a
	 * missing directory, or the target has no `sys` package (e.g.
	 * browser-style js builds).
	 */
	public static function forkRoot(): Null<String> {
		#if (sys || nodejs)
		final root: Null<String> = Sys.getEnv(ENV_KEY);
		return if (root == null || root == '')
			null
		else if (!FileSystem.exists(root) || !FileSystem.isDirectory(root))
			null
		else
			root;
		#else
		return null;
		#end
	}

	/**
	 * Parses a `.hxtest` file at the given absolute path into its
	 * three sections. Returns `null` on malformed files (section
	 * count other than 3) so the harness can count them as skips
	 * without aborting the whole run. Returns `null` on non-`sys`
	 * targets — in practice this path is never reached because
	 * `forkRoot()` already returns `null` there and the consuming
	 * harness skips before calling this helper.
	 */
	public static function readHxTest(path: String): Null<HxTestCase> {
		#if (sys || nodejs)
		final content: String = File.getContent(path);
		final parts: Array<String> = content.split(SECTION_SEP);
		return parts.length != EXPECTED_SECTIONS ? null : {
			config: StringTools.trim(parts[0]),
			input: stripPadNewlines(parts[1]),
			expected: stripPadNewlines(parts[2])
		};
		#else
		return null;
		#end
	}

	/**
	 * Drops exactly one leading and one trailing `\n` — the padding
	 * convention around each section in the `.hxtest` format.
	 * Preserves any further newlines that are meaningful content.
	 */
	private static function stripPadNewlines(s: String): String {
		var r: String = s;
		if (r.length > 0 && r.charAt(0) == '\n') r = r.substr(1);
		return r.length > 0 && r.charAt(r.length - 1) == '\n' ? r.substr(0, r.length - 1) : r;
	}

}
