package dev;

import dev.BaselineWarm.WarmRecipe;
import devkit.Args;

/**
 * The one answer to "what does the command line of `dev land` say": every option of it, read BEFORE the positionals —
 * `Args.positionals` refuses an option not yet taken, so a read placed after it makes that option unknown. The options
 * a command line leaves out are null or empty.
 */
@:nullSafety(Strict)
final class LandArgs {

	public final branch: String;
	public final message: Null<String>;
	public final trailers: Array<String>;
	public final noBattery: Bool;
	public final allowBlast: Bool;
	public final snapshot: Bool;
	public final allow: Array<String>;
	public final full: Bool;
	public final repo: Null<String>;
	public final logs: Null<String>;
	public final resolve: Array<String>;
	public final queue: Null<String>;
	public final recipe: WarmRecipe;

	public function new(argv: Array<String>) {
		final args: Args = new Args(argv);
		message = args.option('-m');
		trailers = Land.metricTrailers(args.option('--rounds'), args.option('--tokens'));
		noBattery = args.flag(Land.NO_BATTERY);
		allowBlast = args.flag('--allow-blast');
		snapshot = args.flag('--snapshot');
		allow = args.options('--allow');
		full = args.flag('--full');
		repo = args.option('--repo');
		logs = args.option('--logs');
		resolve = args.options('--resolve');
		queue = args.option('--queue');
		recipe = { frozen: args.options('--warm-frozen'), infra: args.options('--warm-infra') };
		branch = args.positionals(['<branch>'])[0];
	}

}
