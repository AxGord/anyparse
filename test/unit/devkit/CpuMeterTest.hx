package unit.devkit;

import anyparse.proc.SpawnJob;
import devkit.Command;
import devkit.CpuMeter;
import devkit.Result;
import haxe.Exception;
import sys.FileSystem;
import sys.io.File;

/**
 * `devkit.CpuMeter`: while a meter is active a job a tool starts runs under time(1) and the cpu of the processes that ended is
 * the reading a step takes its difference of; a job already under time(1) is left to its own reading, and a short program keeps
 * its bound.
 */
@:nullSafety(Strict)
final class CpuMeterTest extends Test {

	private static inline final TIME: String = '/usr/bin/time';
	private static inline final REPORT: String = '        2.00 real         1.00 user         0.25 sys\n';

	@:pin('control')
	@:killer('M-CPUMETER-READS-USAGE')
	public function testTheCpuOfAnEndedProcessIsReadOnce(): Void {
		TempDir.with(dir -> {
			CpuMeter.begin(dir.file('usage'), TIME);
			final job: SpawnJob = CpuMeter.wrap({ cmd: 'tool', args: ['one'] });
			File.saveContent(usageOf(job), '');
			Assert.equals(0.0, CpuMeter.reading(), 'time(1) opens its file when the process starts: an empty one is still running');
			Assert.isTrue(FileSystem.exists(usageOf(job)), 'and stays for a later reading');
			File.saveContent(usageOf(job), REPORT);
			Assert.equals(1.25, CpuMeter.reading());
			Assert.equals(1.25, CpuMeter.reading(), 'a usage file is read once');
			CpuMeter.end();
			Assert.isNull(CpuMeter.reading());
		});
	}

	@:pin('control')
	@:killer('M-CPUMETER-WRAP-OFF')
	public function testAJobRunsUnderTimeWithItsOwnArguments(): Void {
		TempDir.with(dir -> {
			CpuMeter.begin(dir.file('usage'), TIME);
			final job: SpawnJob = CpuMeter.wrap({ cmd: 'tool', args: ['one', 'two'] });
			CpuMeter.end();
			Assert.equals(TIME, job.cmd);
			Assert.same(['-l', '-o', usageOf(job), 'tool', 'one', 'two'], job.args);
		});
	}

	@:pin('control')
	@:killer('M-CPUMETER-WRAPS-MEASURED')
	public function testAJobAlreadyUnderTimeIsLeftToItsOwnReading(): Void {
		TempDir.with(dir -> {
			CpuMeter.begin(dir.file('usage'), TIME);
			final job: SpawnJob = CpuMeter.wrap({ cmd: 'lease', args: ['-x', TIME, '-l', 'branch'] });
			CpuMeter.end();
			Assert.equals('lease', job.cmd);
			Assert.same(['-x', TIME, '-l', 'branch'], job.args);
		});
	}

	@:pin('control')
	@:killer('M-CPUMETER-SHORT-BOUND')
	public function testAShortProgramKeepsItsBoundUnderTime(): Void {
		TempDir.with(dir -> {
			CpuMeter.begin(dir.file('usage'), TIME);
			final job: SpawnJob = CpuMeter.wrap({ cmd: 'git', args: ['status'] });
			CpuMeter.end();
			Assert.isTrue((job.timeout ?? 0) > 0);
		});
	}

	public function testNothingIsWrappedWithoutAMeter(): Void {
		final job: SpawnJob = CpuMeter.wrap({ cmd: 'tool', args: ['one'] });
		Assert.equals('tool', job.cmd);
		Assert.same(['one'], job.args);
		Assert.isNull(CpuMeter.reading());
	}

	/** On a platform whose time(1) reports a process tree, a command run by `Command` leaves a usage file the meter then reads. */
	@:pin('control')
	@:killer('M-COMMAND-RUNS-METERED')
	public function testACommandRunsUnderTheMeter(): Void {
		TempDir.with(dir -> {
			final usage: String = dir.file('usage');
			CpuMeter.begin(usage);
			if (CpuMeter.reading() == null) {
				CpuMeter.end();
				Assert.pass('no time(1) reporting a process tree here');
				return;
			}
			final ran: Result = Command.of(['git', '--version']).run();
			final left: Array<String> = FileSystem.readDirectory(usage);
			Assert.isTrue(ran.ok, 'the program ran as it would have');
			Assert.equals(1, left.length, 'its usage was left for the meter');
			Assert.notNull(CpuMeter.reading());
			Assert.equals(0, FileSystem.readDirectory(usage).length, 'and read');
			CpuMeter.end();
			Assert.isFalse(FileSystem.exists(usage), 'the meter leaves nothing behind');
		});
	}

	/** A meter's directory is reused across attempts, so what an interrupted one left in it is neither read nor an obstacle. */
	@:pin('control')
	@:killer('M-CPUMETER-BEGIN-KEEPS-STRAYS')
	public function testAStrayUsageFileIsNotReadAsThisRunsCpu(): Void {
		TempDir.with(dir -> {
			final usage: String = dir.file('usage');
			FileSystem.createDirectory(usage);
			File.saveContent('$usage/0.time', REPORT);
			CpuMeter.begin(usage, TIME);
			final job: SpawnJob = CpuMeter.wrap({ cmd: 'tool', args: [] });
			Assert.equals('$usage/0.time', usageOf(job));
			Assert.equals(0.0, CpuMeter.reading());
			CpuMeter.end();
		});
	}


	public function testEndingTheMeterRemovesItsDirectoryWhateverItHolds(): Void {
		TempDir.with(dir -> {
			final usage: String = dir.file('usage');
			CpuMeter.begin(usage, TIME);
			File.saveContent('$usage/57.time', REPORT);
			final failure: Null<String> = try {
				CpuMeter.end();
				null;
			} catch (exception: Exception) {
				exception.message;
			}
			Assert.isNull(failure, 'ending the meter does not throw');
			Assert.isFalse(FileSystem.exists(usage));
		});
	}

	@:pin('control')
	@:killer('M-CPUMETER-RUNNING-READ-ZERO')
	public function testAProcessStillRunningIsReadWhenItEnds(): Void {
		TempDir.with(dir -> {
			CpuMeter.begin(dir.file('usage'), TIME);
			final job: SpawnJob = CpuMeter.wrap({ cmd: 'tool', args: [] });
			File.saveContent(usageOf(job), '');
			Assert.equals(0.0, CpuMeter.reading());
			File.saveContent(usageOf(job), REPORT);
			Assert.equals(1.25, CpuMeter.reading());
			CpuMeter.end();
		});
	}

	/** The usage file `wrap` named for `job`: the argument after `-o`. */
	private static function usageOf(job: SpawnJob): String {
		return job.args[job.args.indexOf('-o') + 1];
	}

}
