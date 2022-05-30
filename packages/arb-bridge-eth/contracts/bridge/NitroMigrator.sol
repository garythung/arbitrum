// SPDX-License-Identifier: Apache-2.0

/*
 * Copyright 2019-2021, Offchain Labs, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import "./Bridge.sol";
import "./Outbox.sol";
import "./Inbox.sol";
import "./SequencerInbox.sol";
import "../rollup/RollupEventBridge.sol";
import "./Old_Outbox/OldOutbox.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../rollup/facets/RollupAdmin.sol";
import "../rollup/RollupLib.sol";

pragma solidity ^0.6.11;

contract NitroMigrator is Ownable {
    uint8 internal constant L1MessageType_chainHalt = 12;

    Inbox immutable inbox;
    SequencerInbox immutable sequencerInbox;
    Bridge immutable bridge;
    RollupEventBridge immutable rollupEventBridge;
    OldOutbox immutable outboxV1;
    Outbox immutable outboxV2;
    // assumed this contract is now the rollup admin
    RollupAdminFacet immutable rollup;

    address immutable nitroBridge;
    address immutable nitroOutbox;
    address immutable nitroSequencerInbox;
    address immutable nitroInboxLogic;

    // this is used track the message count in which the final inbox message was force included
    // initially set to max uint256. after step 1 its set to sequencer's inbox message count
    uint256 messageCountWithHalt;

    constructor(
        Inbox _inbox,
        SequencerInbox _sequencerInbox,
        Bridge _bridge,
        RollupEventBridge _rollupEventBridge,
        OldOutbox _outboxV1,
        Outbox _outboxV2,
        RollupAdminFacet _rollup,
        address _nitroBridge,
        address _nitroOutbox,
        address _nitroSequencerInbox,
        address _nitroInboxLogic
    ) public Ownable() {
        inbox = _inbox;
        sequencerInbox = _sequencerInbox;
        bridge = _bridge;
        rollupEventBridge = _rollupEventBridge;
        rollup = _rollup;
        outboxV1 = _outboxV1;
        outboxV2 = _outboxV2;
        nitroBridge = _nitroBridge;
        nitroOutbox = _nitroOutbox;
        nitroSequencerInbox = _nitroSequencerInbox;
        nitroInboxLogic = _nitroInboxLogic;
        // setting to max value means it won't be possible to execute step 2 before step 1
        messageCountWithHalt = type(uint256).max;
    }

    /// @dev this assumes this contract owns the rollup/inboxes/bridge before this function is called (else it will revert)
    /// this will create the final input in the inbox, but there won't be the final assertion available yet
    function nitroStep1() external onlyOwner {
        require(messageCountWithHalt == type(uint256).max, "STEP1_ALREADY_TRIGGERED");
        uint256 delayedMessageCount = inbox.chainHalt();

        bridge.setInbox(address(inbox), false);
        bridge.setInbox(address(outboxV1), false);
        bridge.setInbox(address(outboxV2), false);
        // we disable the rollupEventBridge later since its needed in order to create/confirm assertions

        bridge.setOutbox(address(this), true);

        {
            uint256 bal = address(bridge).balance;
            (bool success, ) = bridge.executeCall(nitroBridge, bal, "");
            require(success, "ESCROW_TRANSFER_FAIL");
        }

        bridge.setOutbox(address(this), false);

        // TODO: will this cause a sequencer reorg?
        sequencerInbox.forceInclusionNoDelay(
            delayedMessageCount,
            L1MessageType_chainHalt,
            [block.number, block.timestamp],
            delayedMessageCount,
            tx.gasprice,
            address(this),
            keccak256(abi.encodePacked("")),
            bridge.inboxAccs(delayedMessageCount - 1)
        );

        // we can use this to verify in step 2 that the assertion includes the chainHalt message
        messageCountWithHalt = sequencerInbox.messageCount();

        // TODO: remove permissions from gas refunder to current sequencer inbox

        // TODO: trigger inbox upgrade to new logic
    }

    /// @dev this assumes step 1 has executed succesfully and that a validator has made the final assertion that includes the inbox chainHalt
    function nitroStep2(
        bytes32[3] memory bytes32Fields,
        uint256[4] memory intFields,
        uint256 proposedBlock,
        uint256 inboxMaxCount
    ) external onlyOwner {
        require(inboxMaxCount == messageCountWithHalt, "WRONG_MESSAGE_COUNT");

        RollupLib.ExecutionState memory afterExecutionState = RollupLib.decodeExecutionState(
            bytes32Fields,
            intFields,
            proposedBlock,
            inboxMaxCount
        );
        bytes32 expectedStateHash = RollupLib.stateHash(afterExecutionState);

        // TODO: should we provide the nodeNum instead as a param? can delete anything bigger than it from rollup
        uint256 nodeNum = rollup.latestNodeCreated();
        // the actual nodehash doesn't matter, only its after state of execution
        bytes32 actualStateHash = rollup.getNode(nodeNum).stateHash();
        require(expectedStateHash == actualStateHash, "WRONG_STATE_HASH");

        // TODO: we can forceCreate the assertion and have the rollup paused in step 1
        rollup.pause();
        // we could disable the rollup user facet so only the admin can interact with the rollup
        // would make the dispatch rollup revert when calling user facet. but easier to just pause it

        // TODO: ensure everyone is unstaked?
        // need to wait until last assertion beforeforce confirm assertion
        uint256 stakerCount = rollup.stakerCount();
        address[] memory stakers = new address[](stakerCount);
        for (uint64 i = 0; i < stakerCount; ++i) {
            stakers[i] = rollup.getStakerAddress(i);
        }
        // they now have withdrawable stake to claim
        // rollup needs to be unpaused for this.
        // TODO: we can remove `whenNotPaused` modifier from that function
        rollup.forceRefundStaker(stakers);

        // TODO: forceResolveChallenge if any
        // TODO: double check that challenges can't be created and new stakes cant be added

        bridge.setInbox(address(rollupEventBridge), false);
        // enable new Bridge with funds (ie set old outboxes)
    }
}
