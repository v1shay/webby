# Calculator focus fix

The card layout hid every calculator input before showing the calculator-specific layout. Hiding an NSTextField ends its active field-editor session, so typing/result layout, periodic history refresh and resize could unexpectedly dismiss focus.

The input now stays visible throughout calculator layout. Unchanged history skips layout work. Return calculates through the native editing delegate without ending the edit session; ordinary focus navigation is unchanged.

The isolated native regression test fails on the old implementation and passes after the fix. It types a nested expression, checks editor/caret retention through layout/history/compact and expanded resize, sends Return twice with continued typing, verifies the answers and confirms another field can receive focus normally. Invalid expressions and powers also pass.

Reproduce using the isolated performance harness with `WEBBY_TEST_CALCULATOR_FOCUS=only`; these are functional checks compiled with `-Onone`, not performance measurements. The signed release uses normal optimized build settings. The app was installed without quitting or relaunching the running Webby.
