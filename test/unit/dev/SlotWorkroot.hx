package unit.dev;

import dev.MutationCheck.TrackRow;
import dev.MutationSlot;
import devkit.Cmd.cmd;
import sys.FileSystem;
import sys.io.File;

/** The workroot a `MutationSlot` test runs a track in: slot 1's git tree and the files a parent writes for its slots. */
final class SlotWorkroot {

	/** Create the workroot `workroot` with its slot 1: a git tree holding one committed file, `a.txt`. */
	public static function committedSlot(workroot: String): Void {
		FileSystem.createDirectory(workroot);
		final slot: String = MutationSlot.slotDir(workroot, 1);
		FileSystem.createDirectory(slot);
		cmd('git init -q $slot').check();
		File.saveContent('$slot/a.txt', 'a\n');
		cmd('git -C $slot -c user.name=t -c user.email=t@t add a.txt').check();
		cmd('git -C $slot -c user.name=t -c user.email=t@t commit -q -m a').check();
	}

	/** The files a parent writes for its slots: the rows, their deal order and the owner pid. */
	public static function slotFiles(workroot: String, rows: Array<TrackRow>, owner: String): Void {
		File.saveContent('$workroot/${MutationSlot.ROWS}', rows.map(row -> '${MutationSlot.encodeRow(row)}\n').join(''));
		File.saveContent('$workroot/${MutationSlot.ORDER}', rows.map(row -> '${row.name}\n').join(''));
		File.saveContent('$workroot/${MutationSlot.OWNER}', '$owner\n');
	}

	/** `workroot` holding slot 1 and the one track `name`, whose patch changes `a.txt`, owned by this process. */
	public static function oneTrack(workroot: String, name: String): Void {
		committedSlot(workroot);
		final patch: String = '$workroot/$name.patch';
		File.saveContent(patch, '--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-a\n+b\n');
		slotFiles(workroot, [{
			name: name,
			patch: patch,
			filter: 'ALL',
			expected: ''
		}], '${js.Node.process.pid}');
	}

}
