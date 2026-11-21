package dev;

import devkit.Command;
import devkit.Result;
import devkit.Summary;
import haxe.io.Path;
import sys.FileSystem;

using StringTools;
using Lambda;

/**
 * The one answer to "does every tracked workflow file of a tree still load in the workflow engine": the engine's own loader,
 * reached through its `wf-validate` command under the plugin root a workflow exec names in `WF_PLUGIN_ROOT`. The slice gate
 * and the land's battery both show it, the battery on the candidate tree, which no slice's gate has seen.
 */
@:nullSafety(Strict)
final class WorkflowsRow {

	/** The tracked workflow files' folder, relative to a tree. */
	public static final FOLDER: String = '.claude/workflows';

	/** The loader's command under the plugin root. */
	private static final VALIDATOR: String = 'scripts/wf-validate';

	/** What `wf-validate` prints before the name of a file that loads. */
	private static final LOADED: String = 'ok ';

	/** What `wf-validate` prints before the path of a file that does not load, and the loader's message after it. */
	private static final REFUSED: String = 'fail ';

	/** Whether a slice that touched `touched` can move what loads: a tracked workflow file changed. */
	public static function reached(touched: Array<String>): Bool {
		return touched.exists(file -> file.startsWith('$FOLDER/'));
	}

	/** The row on `tree`, loading through the plugin `root`'s validator; its reading a detail of `summary`. */
	public static function outcome(tree: String, root: Null<String>, summary: Summary): Outcome {
		final script: Null<String> = validator(root);
		if (script == null) return unavailable();
		final run: Result = Command.of([script, FOLDER]).at(tree).run();
		final loaded: Array<String> = run.lines().filter(line -> line.startsWith(LOADED));
		summary.detail('${loaded.length} workflow file(s) load');
		final verdict: Outcome = verdict(run);
		if (!verdict.match(Passed)) summary.excerpt(refusals(run));
		return verdict;
	}

	/** The loader's script under the plugin `root`, or null when there is no root or no script under it. */
	public static function validator(root: Null<String>): Null<String> {
		if (root == null || root == '') return null;
		final script: String = Path.join([root, VALIDATOR]);
		return FileSystem.exists(script) ? script : null;
	}

	/** The verdict when no loader is reachable: the row cannot judge, which fails the run like any row that did not run. */
	public static function unavailable(): Outcome {
		return NotRun('no workflow loader: WF_PLUGIN_ROOT is unset or holds no $VALIDATOR');
	}

	/** The verdict of one `wf-validate` run: passed when it exited 0, else failed with the first message of the loader. */
	public static function verdict(run: Result): Outcome {
		if (run.ok) return Passed;
		final first: Null<String> = refusals(run)[0];
		return Failed(GateTree.clip(first ?? run.firstError()));
	}

	/** Each file the loader refused, as it printed it: the path, then the loader's message. */
	private static function refusals(run: Result): Array<String> {
		return [ for (line in run.lines()) if (line.startsWith(REFUSED)) line.substr(REFUSED.length) ];
	}

}
