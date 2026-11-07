package unit.check.oracle;

import anyparse.check.oracle.CompilerServer;
import anyparse.proc.HaxeSpawn;
import anyparse.proc.PendingRuns;

/**
 * A loopback port something other than a haxe server holds, for the tests of every starter that must keep off one. The one
 * answer to "hold a port and tell whether anything connected to it".
 */
final class PortHolder {

	#if nodejs
	/** How many tenth-seconds a holder is given to say whether it bound its port. */
	private static inline final HOLDER_TRIES: Int = 300;

	/**
	 * Listens on 127.0.0.1 at its last argument and drops every connection unanswered (a silent one would hang the readiness
	 * connect): not a haxe server. It renames into the file its first argument names `listening`, or the bind's error code,
	 * and appends one byte per connection to that name plus `.seen`.
	 */
	private static inline final HOLDER: String = 'const [f,p]=process.argv.slice(-2),fs=require("fs");'
		+ 'const say=s=>{fs.writeFileSync(f+".t",s);fs.renameSync(f+".t",f)};'
		+ 'require("net").createServer(c=>{fs.appendFileSync(f+".seen","c");c.destroy()})'
		+ '.once("error",e=>{say(String(e.code));process.exit(1)})'
		+ '.listen(Number(p),"127.0.0.1",()=>say("listening"))';

	/** A port nothing listens on now, drawn at random. */
	public static function unusedPort(): Int {
		var port: Int = CompilerServer.randomPort();
		while (!CompilerServer.portIsFree(port)) port = CompilerServer.randomPort();
		return port;
	}

	/** `body` run while a holder listens on `port` (`watching`). */
	public static function holding(port: Int, body: () -> Void): Void {
		watching(port, _ -> body());
	}

	/**
	 * `body` run while a holder (`HOLDER`) listens on `port`, once the holder itself said so, given a reading of how many
	 * connections reached it. Never polled through `portIsFree`: a bind probe run while the holder boots can take the port first,
	 * the holder then dies on EADDRINUSE and every later probe reads free. A tethered job: ended after `body`, and gone with this
	 * process should that be killed first.
	 */
	public static function watching(port: Int, body: (connections:() -> Int) -> Void): Void {
		final dir: String = CliFixture.writeDir('apq_port_holder', []);
		final said: String = '$dir/said';
		final seen: String = '$said.seen';
		final holder: PendingRuns = HaxeSpawn.startAll([
			{
				cmd: js.Node.process.execPath,
				args: ['-e', HOLDER, said, '$port'],
				cwd: dir,
				tethered: true
			}
		], 1024, 1);
		CliFixture.always(() -> {
			holder.cancel();
			CliFixture.removeDir(dir);
		}, () -> {
			var tries: Int = 0;
			while (!sys.FileSystem.exists(said) && ++tries < HOLDER_TRIES) Sys.sleep(0.1);
			final state: String = sys.FileSystem.exists(said) ? sys.io.File.getContent(said) : 'nothing after $tries tries';
			Assert.equals('listening', state, 'the holder binds $port');
			if (state == 'listening') body(() -> sys.FileSystem.exists(seen) ? sys.io.File.getContent(seen).length : 0);
		});
	}
	#end

}
