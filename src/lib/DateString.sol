// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

library DateString {
    function toPaddedString(uint256 timestamp) internal pure returns (string memory) {
        // Convert a number of days into a human-readable date, courtesy of BokkyPooBah.
        // Source:
        // https://github.com/bokkypoobah/BokkyPooBahsDateTimeLibrary/blob/master/contracts/BokkyPooBahsDateTimeLibrary.sol

        uint256 year;
        uint256 month;
        uint256 day;
        {
            int256 __days = int256(int256(timestamp) / 1 days);

            int256 num1 = __days + 68_569 + 2_440_588; // 2440588 = OFFSET19700101
            int256 num2 = (4 * num1) / 146_097;
            num1 = num1 - (146_097 * num2 + 3) / 4;
            int256 _year = (4000 * (num1 + 1)) / 1_461_001;
            num1 = num1 - (1461 * _year) / 4 + 31;
            int256 _month = (80 * num1) / 2447;
            int256 _day = num1 - (2447 * _month) / 80;
            num1 = _month / 11;
            _month = _month + 2 - 12 * num1;
            _year = 100 * (num2 - 49) + _year + num1;

            year = uint256(_year);
            month = uint256(_month);
            day = uint256(_day);
        }

        string memory yearStr = Strings.toString(year % 10_000);
        string memory monthStr =
            month < 10 ? string(abi.encodePacked("0", Strings.toString(month))) : Strings.toString(month);
        string memory dayStr = day < 10 ? string(abi.encodePacked("0", Strings.toString(day))) : Strings.toString(day);

        return string.concat(yearStr, "-", monthStr, "-", dayStr);
    }
}
