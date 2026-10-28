package devkit;

import haxe.Exception;
import haxe.io.Path;
import js.node.Fs;
import sys.FileSystem;

/**
 * A count that survives runs and is safe beside other processes: each claim creates the file named by the next number
 * with exclusive-create, so two claimants can never be handed the same number and no lock exists to be left behind.
 * Files below the claimed number are pruned; the highest one is the count.
 */
@:nullSafety(Strict)
final class Tally {

	/** The error code of an exclusive create whose file exists. */
	private static inline final EXISTS: String = 'EEXIST';

	/** The error code of a removal whose file is already gone. */
	private static inline final ABSENT: String = 'ENOENT';

	/** Claim the next number of the tally kept in `dir` (made if missing); the first claim answers 1. */
	public static function next(dir: String): Int {
		if (!FileSystem.exists(dir)) FileSystem.createDirectory(dir);
		var number: Int = highest(dir) + 1;
		while (!claim(Path.join([dir, '$number']))) number++;
		for (old in FileSystem.readDirectory(dir)) {
			final n: Null<Int> = numberOf(old);
			if (n != null && n < number) remove(Path.join([dir, old]));
		}
		return number;
	}

	/** Delete `file`; a file another claimant pruned first is no error. */
	public static function remove(file: String): Void {
		try {
			Fs.unlinkSync(file);
		} catch (error: Exception) {
			if (Reflect.field(error.native, 'code') != ABSENT) throw error;
		}
	}

	/** The highest number claimed in `dir`, 0 when none. */
	private static function highest(dir: String): Int {
		var top: Int = 0;
		for (name in FileSystem.readDirectory(dir)) {
			final n: Null<Int> = numberOf(name);
			if (n != null && n > top) top = n;
		}
		return top;
	}

	/** The number a file name spells, null for any other name. */
	private static function numberOf(name: String): Null<Int> {
		final n: Null<Int> = Std.parseInt(name);
		return n != null && '$n' == name ? n : null;
	}

	/** Whether this call created `file`; false when it already existed. */
	private static function claim(file: String): Bool {
		try {
			Fs.closeSync(Fs.openSync(file, 'wx'));
			return true;
		} catch (error: Exception) {
			if (Reflect.field(error.native, 'code') != EXISTS) throw error;
			return false;
		}
	}

}
