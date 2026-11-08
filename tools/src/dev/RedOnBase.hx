package dev;

import dev.BaseSuite.BaseSuiteRun;
import dev.Shard.Tally;
import devkit.Cmd.cmd;
import devkit.Lease.LeaseMode;
import devkit.Result;
import devkit.Summary.Outcome;
import haxe.io.Path;

using StringTools;

/** What a red row of a candidate reads on the candidate's base. */
enum OnBase {

	/** Every failing item of the candidate is red there too. */
	Red(names: Array<String>);

	/** Some of the candidate's failing items are red there (`red`), the others are not (`green`): the candidate brought those. */
	Partly(red: Array<String>, green: Array<String>);

	/** Green there: the candidate brought the failure. */
	Green;

	/** The base could not be re-run, or its re-run read nothing. */
	Unknown(why: String);

}

/** Where and how a re-run on the base is made. */
typedef BaseRerun = {

	/** The candidate's repository; the base commit is one of its objects. */
	var repo: String;

	/** The base commit, or null when the run compares with none. */
	var base: Null<String>;

	/** The transcript of the base's build. */
	var log: String;
	var shards: Int;
	var mode: LeaseMode;

}

/**
 * The one answer to "is a red row of a candidate also red on the candidate's base": a failing suite class or kit area is
 * re-run in a detached tree of the base, so a red main is never taken for a flake of the candidate.
 */
@:nullSafety(Strict)
final class RedOnBase {

	/** The classes a note names before it counts the rest. */
	private static inline final NAMES_SHOWN: Int = 5;

	/** The classes of the tests `failing` names (`Class.method`), each once, in order of appearance. */
	public static function classesOf(failing: Array<String>): Array<String> {
		final classes: Array<String> = [];
		for (name in failing) {
			final dot: Int = name.lastIndexOf('.');
			final cls: String = dot < 0 ? name : name.substr(0, dot);
			if (!classes.contains(cls)) classes.push(cls);
		}
		return classes;
	}

	/** The `classes` the base registers (`registered` is its `--list-classes`): a class the candidate added cannot be red there. */
	public static function present(classes: Array<String>, registered: String): Array<String> {
		final known: Array<String> = registered.split('\n').map(line -> line.trim());
		return classes.filter(cls -> known.contains(cls));
	}

	/**
	 * The reading of a re-run of the candidate's `candidate` failures (`Class.method`) on the base: its exit `status`, its `totals`
	 * and the tests it named red (`baseRed`). A red run that names no test did not finish, which says nothing about the base.
	 */
	public static function ofSuite(status: Int, totals: Null<Tally>, baseRed: Array<String>, candidate: Array<String>): OnBase {
		if (totals == null || totals.tests == 0) return Unknown('the base re-run counted no tests');
		if (status == 0) return compare(candidate, []);
		if (baseRed.length == 0) return Unknown('the base re-run was red but named no failing test');
		return compare(candidate, baseRed);
	}

	/** `answer` as the row's `red on base:` text. */
	public static function note(answer: OnBase): String {
		return switch answer {
			case Red(names): 'red on base: yes (${shown(names)})';
			case Partly(red, green): 'red on base: partly (yes: ${shown(red)}; no: ${shown(green)})';
			case Green: 'red on base: no';
			case Unknown(why): 'red on base: unknown ($why)';
		};
	}

	/** A row's failure `why` followed by what the base says. */
	public static function reason(why: String, answer: OnBase): String {
		return '$why; ${note(answer)}';
	}

	/**
	 * `body` over a detached tree of the base (`GateTree.withCheckout`), built by `build`; a base that has no tree, does not build or
	 * whose `body` throws reads `Unknown`.
	 */
	public static function onBase(request: BaseRerun, build: String -> Outcome, body: String -> OnBase): OnBase {
		final base: Null<String> = request.base;
		if (base == null) return Unknown('the run compares with no base');
		final answered: Array<OnBase> = [];
		final outcome: Outcome = GateTree.withCheckout(
			request.repo, base, checkout -> switch build(checkout) {
				case Failed(why), NotRun(why): Failed('the base did not build: $why');
				case _:
					answered.push(body(checkout));
					Passed;
			}
		);
		return switch outcome {
			case Failed(why), NotRun(why): Unknown(GateTree.clip(why));
			case _: answered[0] ?? Unknown('the base was not read');
		};
	}

	/** The candidate's failing tests `candidate` (`Class.method`), their classes re-run on the base. */
	public static function suite(request: BaseRerun, candidate: Array<String>): OnBase {
		final classes: Array<String> = classesOf(candidate);
		return classes.length == 0
			? Unknown('the failing run names no test class')
			: onBase(
				request, checkout -> Binaries.compileBuilds(checkout, request.log, BaseSuite.builds(), request.mode),
				checkout -> rerun(request, checkout, classes, candidate)
			);
	}

	/**
	 * The kit rows (`KitsReport.rows`) `candidate` fails, the base's kits run: a row is red there only where the same row of the same
	 * area is, so a second broken row of an area already red on the base reads as the candidate's own.
	 */
	public static function kits(request: BaseRerun, candidate: Array<String>): OnBase {
		return onBase(
			request, checkout -> Binaries.compileBuilds(checkout, request.log, [['bin/apq-js.hxml']], request.mode),
			checkout -> compare(candidate, Probe.checkAll(checkout).rows)
		);
	}

	/** A row's `outcome`, a failure of it followed by what `rerun` reads on the base; the re-run is made only for a failure. */
	public static function after(outcome: Outcome, rerun: () -> OnBase): Outcome {
		return switch outcome {
			case Failed(why): Failed(reason(why, rerun()));
			case other: other;
		};
	}

	/** The re-run of the row `row` of the battery `plan`: its tree and transcripts among the run's work files. */
	public static function requestFor(plan: BatteryPlan, row: String, mode: LeaseMode): BaseRerun {
		return {
			repo: plan.repo,
			base: plan.base,
			log: Path.join([plan.work, 'red-on-base-$row.log']),
			shards: plan.shards,
			mode: mode
		};
	}

	/**
	 * Which of the `candidate`'s failing items (tests, kit areas) are also failing on the base (`base`): all, none, or some. An item the
	 * base does not name — a test of a class the candidate added too — is not red there.
	 */
	public static function compare(candidate: Array<String>, base: Array<String>): OnBase {
		if (candidate.length == 0) return Unknown('the candidate names no failing item');
		final red: Array<String> = candidate.filter(item -> base.contains(item));
		final green: Array<String> = candidate.filter(item -> !base.contains(item));
		if (green.length == 0) return Red(red);
		return red.length == 0 ? Green : Partly(red, green);
	}

	private static function rerun(request: BaseRerun, checkout: String, classes: Array<String>, candidate: Array<String>): OnBase {
		final listed: Result = cmd('node bin/test.js --list-classes').at(checkout).run();
		if (!listed.ok) return Unknown(GateTree.clip('the base runner lists no classes: ${listed.firstError()}'));
		final here: Array<String> = present(classes, listed.out);
		if (here.length == 0) return compare(candidate, []);
		final failing: Array<String> = [];
		final run: BaseSuiteRun = BaseSuite.runIn(checkout, request.shards, here, '${request.log}.suite', names -> for (name in names)
			failing.push(name));
		return ofSuite(run.status, run.totals, failing, candidate);
	}

	/** The first few of `names`, and how many more there are. */
	private static function shown(names: Array<String>): String {
		final more: String = names.length > NAMES_SHOWN ? ', … +${names.length - NAMES_SHOWN} more' : '';
		return names.slice(0, NAMES_SHOWN).join(', ') + more;
	}

}
