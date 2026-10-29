// Unit tests for the secret header parsing and comparison used by the webhook
// handler. Run with:
//   npx deno@2 test --allow-env supabase/functions

import {
  MIN_SECRET_LENGTH,
  readPresentedSecret,
  SECRET_HEADER,
  secretsMatch,
} from './webhook_secret.ts';

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals(
  actual: unknown,
  expected: unknown,
  message: string,
): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(`${message}\n  expected: ${e}\n  actual:   ${a}`);
  }
}

function request(headers: Record<string, string>): Request {
  return new Request('http://localhost/notify-new-message', {
    method: 'POST',
    headers,
    body: '{}',
  });
}

const SECRET = 'a'.repeat(MIN_SECRET_LENGTH);

Deno.test('reads the dedicated header', () => {
  assertEquals(
    readPresentedSecret(request({ [SECRET_HEADER]: SECRET })),
    SECRET,
    'custom header',
  );
});

Deno.test('reads a Bearer Authorization header in any case', () => {
  for (
    const value of [`Bearer ${SECRET}`, `bearer ${SECRET}`, `BEARER ${SECRET}`]
  ) {
    assertEquals(
      readPresentedSecret(request({ authorization: value })),
      SECRET,
      value,
    );
  }
});

Deno.test('trims surrounding whitespace but not interior characters', () => {
  assertEquals(
    readPresentedSecret(request({ [SECRET_HEADER]: `  ${SECRET}  ` })),
    SECRET,
    'trimmed',
  );
  assertEquals(
    readPresentedSecret(request({ [SECRET_HEADER]: `${SECRET} ` })),
    SECRET,
    'trailing space',
  );
});

Deno.test('the dedicated header wins when both are present', () => {
  // An operator who leaves a stale Authorization value must not authenticate
  // with it.
  assertEquals(
    readPresentedSecret(
      request({ [SECRET_HEADER]: SECRET, authorization: 'Bearer stale-value' }),
    ),
    SECRET,
    'custom header precedence',
  );
});

Deno.test('returns null when no usable credential is present', () => {
  const cases: Array<Record<string, string>> = [
    {},
    { [SECRET_HEADER]: '' },
    { [SECRET_HEADER]: '   ' },
    { authorization: '' },
    { authorization: 'Basic dXNlcjpwYXNz' },
    { authorization: 'Bearer' },
    { authorization: `Token ${SECRET}` },
  ];
  for (const headers of cases) {
    assertEquals(
      readPresentedSecret(request(headers)),
      null,
      JSON.stringify(headers),
    );
  }
});

Deno.test('compares secrets by value, independent of length', async () => {
  assert(await secretsMatch(SECRET, SECRET), 'identical values match');
  assert(!(await secretsMatch(SECRET, `${SECRET}b`)), 'longer value differs');
  assert(!(await secretsMatch(`${SECRET}b`, SECRET)), 'shorter value differs');
  assert(!(await secretsMatch('', SECRET)), 'empty differs');
  assert(
    !(await secretsMatch(SECRET.toUpperCase(), SECRET)),
    'comparison is case sensitive',
  );
  assert(
    !(await secretsMatch('b'.repeat(64), 'a'.repeat(64))),
    'different bytes differ',
  );
});

Deno.test('the comparison never throws on unusual input', async () => {
  // A hostile caller controls this string entirely; it must not be able to make
  // the check throw its way past authentication.
  for (const value of ['ü'.repeat(64), '\u0000', ' ', '🔐'.repeat(8)]) {
    assert(!(await secretsMatch(value, SECRET)), JSON.stringify(value));
  }
});

Deno.test('the minimum length is the documented 32 characters', () => {
  assertEquals(MIN_SECRET_LENGTH, 32, 'minimum length');
});
