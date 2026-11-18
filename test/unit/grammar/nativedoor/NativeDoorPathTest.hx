package unit.grammar.nativedoor;

import anyparse.format.WriteOptions;
import anyparse.grammar.json.JsonFormat;
import utest.Assert;
import utest.Test;

/** Which writer a generated writer's `write` picks: the door's for the format's compact options, the Doc writer for any other. */
class NativeDoorPathTest extends Test {

	/**
	 * The compact options take the door's writer, and its `JSON.stringify` writes a number JSON cannot spell as `null`; a
	 * structural copy of those options is no longer the compact ones and takes the Doc writer, which spells the number.
	 */
	@:pin('control')
	@:killer('M-NATIVE-COMPACT-NEVER')
	public function testTheCompactOptionsTakeTheDoorWriter(): Void {
		final record: DoorRecord = {
			first: null,
			name: 'a',
			size: 1,
			ratio: Math.NaN,
			on: true,
			member: 'f',
			points: [],
			rows: [],
			holes: [],
			inner: { n: 1, label: null },
			kids: [],
			tail: null
		};
		final compact: WriteOptions = JsonFormat.instance.compactWriteOptions;
		final copy: WriteOptions = Reflect.copy(compact);
		#if js
		Assert.stringContains('"ratio":null', DoorRecordWriter.write(record, compact));
		Assert.stringContains('"ratio":NaN', DoorRecordWriter.write(record, copy));
		#else
		Assert.pass();
		#end
	}

}
