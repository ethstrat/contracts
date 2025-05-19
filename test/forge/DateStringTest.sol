// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";

import {DateString} from "../../src/lib/DateString.sol";

contract DateStringTest is Test {
    function setUp() public {}

    // when the date of the month is < 10
    //  [X] it should be padded with a 0
    // when the month is < 10
    //  [X] it should be padded with a 0
    // [X] it should be formatted as YYYY-MM-DD

    function test_standard() public pure {
        assertEq(DateString.toPaddedString(1760724244), "2025-10-17");
    }

    function test_date_less_than_10() public pure {
        assertEq(DateString.toPaddedString(1759687444), "2025-10-05");
    }

    function test_month_less_than_10() public pure {
        assertEq(DateString.toPaddedString(1744394644), "2025-04-11");
    }
}
