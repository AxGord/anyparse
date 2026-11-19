package unit.dev;

import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
 * The tracked `.claude/workflows` folder is portable: no file of it names a path of one machine, so a checkout anywhere
 * renders the same workflows through `{{project_root}}`; an exec command reads the checkout from the quoted
 * `$WF_PROJECT_ROOT` instead, since an unquoted interpolation breaks on a path holding a space. The per-machine toggle
 * `lib/recon-arm` is the one file the folder leaves ignored, and is not read here.
 */
@:nullSafety(Strict)
final class TrackedWorkflowsTest extends utest.Test {

	private static final ROOT: String = '.claude/workflows';
	private static final MACHINE_PATHS: Array<String> = ['/Users/', '/home/', 'C:\\', '$$HOME/dev', 'mcp-workflow-engine/'];

	public function testNoTrackedWorkflowFileNamesAPathOfOneMachine(): Void {
		final files: Array<String> = filesUnder(ROOT);
		utest.Assert.isTrue(files.length > 0, 'the workflows folder is read from the repository root');
		for (file in files) {
			final text: String = File.getContent(file);
			for (path in MACHINE_PATHS) utest.Assert.isFalse(text.contains(path), '$file names $path');
		}
	}

	public function testNoExecCommandInterpolatesTheProjectRootUnquoted(): Void {
		for (file in filesUnder(ROOT)) if (file.endsWith('.yaml')) {
			var inCommand: Bool = false;
			for (line in File.getContent(file).split('\n')) {
				if (line.startsWith('    ') && !line.startsWith('     ')) inCommand = line.startsWith('    command:');
				if (inCommand)
					utest.Assert.isFalse(
						line.contains('{{project_root}}'), '$file: a command interpolates {{project_root}}: ${line.trim()}'
					);
			}
		}
	}

	private static function filesUnder(dir: String): Array<String> {
		final out: Array<String> = [];
		if (!FileSystem.exists(dir)) return out;
		for (entry in FileSystem.readDirectory(dir)) {
			final path: String = '$dir/$entry';
			if (FileSystem.isDirectory(path))
				for (nested in filesUnder(path)) out.push(nested);
			else if (path != '$ROOT/lib/recon-arm')
				out.push(path);
		}
		return out;
	}

}
