package unit;

import anyparse.grammar.ar.ArArchive;
import anyparse.grammar.ar.ArArchiveFastParser;
import anyparse.grammar.ar.ArArchiveFastWriter;
import anyparse.grammar.ar.ArEntry;
import haxe.io.Bytes;
import utest.Assert;

/**
 * Tests for the macro-generated ar archive parser and writer.
 *
 * Covers:
 *  - Structural parsing of hand-built ar archives
 *  - Round-trip (build → write → parse → compare)
 *  - Real .ipk file compatibility
 */
class ArParserTest extends utest.Test {

	/** File mode for a regular file with 0644 permissions (octal 100644). */
	private static final MODE_REGULAR_FILE:Int = 33188;

	/** Build a minimal ar archive in memory with one entry. */
	private static function buildMinimalAr():Bytes {
		final output:haxe.io.BytesOutput = new haxe.io.BytesOutput();
		// Magic
		output.writeString('!<arch>\n');
		// Entry header (60 bytes)
		output.writeString('hello.txt/      '); // name: 16 bytes
		output.writeString('1700000000  ');      // mtime: 12 bytes
		output.writeString('1000  ');            // owner: 6 bytes
		output.writeString('1000  ');            // group: 6 bytes
		output.writeString('100644  ');          // mode: 8 bytes
		output.writeString('5         ');        // size: 10 bytes
		output.writeString('`\n');               // fmag: 2 bytes
		// Data (5 bytes)
		output.writeString('hello');
		// Padding (5 is odd → 1 byte pad)
		output.writeByte(0x0A);
		return output.getBytes();
	}

	/** Build an ar archive with two entries. */
	private static function buildTwoEntryAr():Bytes {
		final output:haxe.io.BytesOutput = new haxe.io.BytesOutput();
		output.writeString('!<arch>\n');
		// Entry 1: even size (no padding)
		output.writeString('file1.txt/      '); // 16
		output.writeString('1700000001  ');      // 12
		output.writeString('0     ');            // 6
		output.writeString('0     ');            // 6
		output.writeString('100644  ');          // 8
		output.writeString('4         ');        // 10
		output.writeString('`\n');               // 2
		output.writeString('abcd');              // 4 bytes (even, no pad)
		// Entry 2: odd size (1 byte padding)
		output.writeString('file2.txt/      '); // 16
		output.writeString('1700000002  ');      // 12
		output.writeString('0     ');            // 6
		output.writeString('0     ');            // 6
		output.writeString('100644  ');          // 8
		output.writeString('3         ');        // 10
		output.writeString('`\n');               // 2
		output.writeString('xyz');               // 3 bytes
		output.writeByte(0x0A);                  // padding
		return output.getBytes();
	}

	public function testParseMinimalAr():Void {
		final ar:ArArchive = ArArchiveFastParser.parse(buildMinimalAr());
		Assert.equals(1, ar.entries.length);
		final e:ArEntry = ar.entries[0];
		Assert.equals('hello.txt/', e.name);
		Assert.equals(5, e.data.length);
		Assert.equals('hello', e.data.toString());
	}

	public function testParseTwoEntries():Void {
		final ar:ArArchive = ArArchiveFastParser.parse(buildTwoEntryAr());
		Assert.equals(2, ar.entries.length);
		Assert.equals('abcd', ar.entries[0].data.toString());
		Assert.equals('xyz', ar.entries[1].data.toString());
	}

	public function testHeaderFields():Void {
		final ar:ArArchive = ArArchiveFastParser.parse(buildMinimalAr());
		final e:ArEntry = ar.entries[0];
		Assert.equals(1700000000, e.mtime);
		Assert.equals(1000, e.ownerId);
		Assert.equals(1000, e.groupId);
		Assert.equals(MODE_REGULAR_FILE, e.mode);
	}

	public function testWriteMinimal():Void {
		final ar:ArArchive = ArArchiveFastParser.parse(buildMinimalAr());
		final written:Bytes = ArArchiveFastWriter.write(ar);
		final original:Bytes = buildMinimalAr();
		Assert.equals(original.length, written.length);
		Assert.equals(0, original.compare(written));
	}

	public function testRoundTripTwoEntries():Void {
		final original:Bytes = buildTwoEntryAr();
		final ar:ArArchive = ArArchiveFastParser.parse(original);
		final written:Bytes = ArArchiveFastWriter.write(ar);
		Assert.equals(original.length, written.length);
		Assert.equals(0, original.compare(written));
	}

	public function testWriteThenParse():Void {
		final entry:ArEntry = {
			name: 'test.dat/',
			mtime: 1700000000,
			ownerId: 0,
			groupId: 0,
			mode: MODE_REGULAR_FILE,
			data: Bytes.ofString('foobar'),
		};
		final archive:ArArchive = {entries: [entry]};
		final written:Bytes = ArArchiveFastWriter.write(archive);
		final parsed:ArArchive = ArArchiveFastParser.parse(written);
		Assert.equals(1, parsed.entries.length);
		Assert.equals('foobar', parsed.entries[0].data.toString());
		Assert.equals('test.dat/', parsed.entries[0].name);
	}

	public function testRejectsBadMagic():Void {
		final bad:Bytes = Bytes.ofString('BADMAGIC\nhello');
		Assert.raises(() -> ArArchiveFastParser.parse(bad));
	}
}
