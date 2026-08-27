# Changelog

## [8.0.0](https://github.com/Assetera-AG/AsseteraEvmContracts/compare/evm-contracts-v7.0.1...evm-contracts-v8.0.0) (2026-08-27)


### ⚠ BREAKING CHANGES

* **exchange:** `makeOffer` gains a leading `uint256 orderId`, so its selector becomes 0x03269a4a. `OfferMade` and `OfferAccepted` each gain a trailing `uint256 orderId`, so their topic0 changes and an indexer on the old topics stops matching them. Storage is NOT broken: `orderId` is appended to a struct held in a mapping, so this installs over a live 4.0.0 proxy with a plain `upgradeToAndCall` and every existing offer reads back with `orderId == 0`.

### Features

* **exchange:** an offer draws on, and closes, the order it was raised against (AO-746) ([#83](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/83)) ([c0ad52d](https://github.com/Assetera-AG/AsseteraEvmContracts/commit/c0ad52d2c7332a687c898980e64e84a2db319808))
* **primary:** buy in one transaction, by inheriting the permit relay (AO-716) ([#82](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/82)) ([1cf635a](https://github.com/Assetera-AG/AsseteraEvmContracts/commit/1cf635ab83a36c0d644f6ccd03a0b6af67fdf4a1))

## [7.0.1](https://github.com/Assetera-AG/AsseteraEvmContracts/compare/evm-contracts-v7.0.0...evm-contracts-v7.0.1) (2026-08-24)


### Bug Fixes

* **sdk:** document that implementations is a snapshot, not a live view ([#80](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/80)) ([e5bbf68](https://github.com/Assetera-AG/AsseteraEvmContracts/commit/e5bbf689764e0b4c56d99f91610b8a57bca6c369))

## [7.0.0](https://github.com/Assetera-AG/AsseteraEvmContracts/compare/evm-contracts-v6.1.0...evm-contracts-v7.0.0) (2026-08-24)


### ⚠ BREAKING CHANGES

* **sdk:** the published ABI now carries AO-713's SettlementIntent, which gained a `uint8 accountingMode` member. INTENT_TYPEHASH is now 0xa24f008693b1ca921f2aca00e79f4bc40748d499f86d54d0d8377dfdc884bf68, the settlePrimary selector has moved, and every EIP-712 digest and paramsHash binding changes with them. Consumers encoding a SettlementIntent must add the member; nothing else in the package is affected, and nothing currently encodes one.

### Features

* **sdk:** publish the AO-713 intent ABI, and commit + guard the generated surface ([#76](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/76)) ([656622c](https://github.com/Assetera-AG/AsseteraEvmContracts/commit/656622c52a924399ca1bdd2ff60f569b6a199ddd))

## [6.1.0](https://github.com/Assetera-AG/AsseteraEvmContracts/compare/evm-contracts-v6.0.0...evm-contracts-v6.1.0) (2026-08-20)


### Features

* **deployments:** go live on Polygon and Ethereum mainnet ([#73](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/73)) ([8a53167](https://github.com/Assetera-AG/AsseteraEvmContracts/commit/8a53167855e9a1dccbed3c1792bb1ab678a27141))

## [6.0.0](https://github.com/Assetera-AG/AsseteraEvmContracts/compare/evm-contracts-v5.0.0...evm-contracts-v6.0.0) (2026-08-18)


### ⚠ BREAKING CHANGES

* **sdk:** export getPrimarySalesAddress, which shipped unreachable in 5.0.0 ([#66](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/66))

### Bug Fixes

* **sdk:** export getPrimarySalesAddress, which shipped unreachable in 5.0.0 ([#66](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/66)) ([279a710](https://github.com/Assetera-AG/AsseteraEvmContracts/commit/279a7103b5d4b632dfec7196b029b95492c5ad1a))

## [5.0.0](https://github.com/Assetera-AG/AsseteraEvmContracts/compare/evm-contracts-v4.1.0...evm-contracts-v5.0.0) (2026-08-18)


### ⚠ BREAKING CHANGES

* **script:** rename the exchange salt labels and make the deploy-support scripts usable ([#62](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/62))
* **primary:** the exchange deploys to a new address on every chain. The existing testnet orders, offers and escrow are NOT migrated — they stay on the old proxy, which this source tree no longer describes. Every consumer (SDK deployment records, indexer, signer service, fronts) must re-point to the new address once the deploy has run.

### Features

* **primary:** add the primary settlement contract (AO-560) ([#58](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/58)) ([c975d39](https://github.com/Assetera-AG/AsseteraEvmContracts/commit/c975d39b7ca22cb15098e1a424a55ecae6b1c6b2))


### Refactors

* **script:** rename the exchange salt labels and make the deploy-support scripts usable ([#62](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/62)) ([b140fd7](https://github.com/Assetera-AG/AsseteraEvmContracts/commit/b140fd792b715f5612b1b669abe08675ea88dd4f))

## [4.1.0](https://github.com/Assetera-AG/AsseteraEvmContracts/compare/evm-contracts-v4.0.2...evm-contracts-v4.1.0) (2026-08-05)


### Features

* **exchange:** let takers and offer parties pay by signature (AO-298) ([#53](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/53)) ([70287c0](https://github.com/Assetera-AG/AsseteraEvmContracts/commit/70287c0704b9811171b1fe96bccb1134ffc48471))

## [4.0.2](https://github.com/Assetera-AG/AsseteraEvmContracts/compare/evm-contracts-v4.0.1...evm-contracts-v4.0.2) (2026-07-31)


### Bug Fixes

* **sdk:** declare the repository so provenance validation passes ([#50](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/50)) ([c2c2af0](https://github.com/Assetera-AG/AsseteraEvmContracts/commit/c2c2af06498389e35a87779c4f5d94598a7ca102))

## [4.0.1](https://github.com/Assetera-AG/AsseteraEvmContracts/compare/evm-contracts-v4.0.0...evm-contracts-v4.0.1) (2026-07-31)


### Bug Fixes

* **exchange:** verify fee attestations regardless of the KYC toggle (AC-884) ([#48](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/48)) ([47171e4](https://github.com/Assetera-AG/AsseteraEvmContracts/commit/47171e41076614801c7624ffab7f6769b286e732))

## [4.0.0](https://github.com/Assetera-AG/AsseteraEvmContracts/compare/evm-contracts-v3.0.0...evm-contracts-v4.0.0) (2026-07-29)


### ⚠ BREAKING CHANGES

* **ecs:** the SDK's generated symbols and deployment-artifact JSON keys are renamed. asseteraExchangeAbi -> asseteraEcsAbi; asseteraExchangeAddress / asseteraExchangeConfig -> asseteraEcsAddress / asseteraEcsConfig; useReadAsseteraExchange* / useWriteAsseteraExchange* / useSimulateAsseteraExchange* / useWatchAsseteraExchange* -> *AsseteraEcs*; getContractAddress(id, "AsseteraExchange") -> getContractAddress(id, "AsseteraECS"); deployment.contracts.AsseteraExchange and deployment.implementations.AsseteraExchange -> .AsseteraECS. getExchangeAddress() still works but is deprecated in favour of getEcsAddress(). Consumers that read the deployment key raw (the Subsquid indexer) must change the key in the same PR as the dependency bump. On-chain addresses and the EIP-712 domain are unchanged.

### Features

* **ecs:** rename AsseteraExchange to AsseteraECS (AC-837, AC-838) ([#43](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/43)) ([f81e0a1](https://github.com/Assetera-AG/AsseteraEvmContracts/commit/f81e0a1ba3b22027a9b7efd1128fd3a422c012ae))

## [3.0.0](https://github.com/Assetera-AG/AsseteraEvmContracts/compare/evm-contracts-v2.0.2...evm-contracts-v3.0.0) (2026-07-28)


### ⚠ BREAKING CHANGES

* **exchange:** FEE_TYPEHASH gains `address feeToken`, so the fee service must sign the new type. Fill/settle events carry gross amounts plus feeToken; OrderPartiallyFilled additionally carries filledBuyAmount.

### Features

* **exchange:** denominate both fees in the settlement currency, exclusive on the payer (AC-833) ([#39](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/39)) ([8360e3d](https://github.com/Assetera-AG/AsseteraEvmContracts/commit/8360e3d74e87f9ef9ee7085ff4bf48d874d34e7c))

## [2.0.2](https://github.com/Assetera-AG/AsseteraEvmContracts/compare/evm-contracts-v2.0.1...evm-contracts-v2.0.2) (2026-07-20)


### Bug Fixes

* **deploy:** preserve proxy deployBlock across impl upgrades (AC-668) ([#35](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/35)) ([f432035](https://github.com/Assetera-AG/AsseteraEvmContracts/commit/f43203544bff20bcc9765eaae02cba47baba8dca))

## [2.0.1](https://github.com/Assetera-AG/AsseteraEvmContracts/compare/evm-contracts-v2.0.0...evm-contracts-v2.0.1) (2026-07-17)


### Bug Fixes

* **sdk:** redeploy AsseteraExchange to Amoy/Sepolia with order/offer event parity ([#33](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/33)) ([f37eebc](https://github.com/Assetera-AG/AsseteraEvmContracts/commit/f37eebcb500a648a8d57bf3a74a20ce05c6b2634))

## [2.0.0](https://github.com/Assetera-AG/AsseteraEvmContracts/compare/evm-contracts-v1.0.0...evm-contracts-v2.0.0) (2026-07-13)


### ⚠ BREAKING CHANGES

* **contracts:** drop unused operator param from initialize(); Fresh Amoy/Sepolia deployments recorded. ([#22](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/22))

### Refactors

* **contracts:** drop unused operator param from initialize(); Fresh Amoy/Sepolia deployments recorded. ([#22](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/22)) ([78aee84](https://github.com/Assetera-AG/AsseteraEvmContracts/commit/78aee84c48e138c0a57fa4422e18e134a4f95456))

## [1.0.0](https://github.com/Assetera-AG/AsseteraEvmContracts/compare/evm-contracts-v0.2.0...evm-contracts-v1.0.0) (2026-07-10)


### ⚠ BREAKING CHANGES

* **contracts:** park operator functions, settle offers atomically on accept (AC-246) ([#20](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/20))

### Features

* **contracts:** park operator functions, settle offers atomically on accept (AC-246) ([#20](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/20)) ([74c397c](https://github.com/Assetera-AG/AsseteraEvmContracts/commit/74c397c2cec910f87a4d45655da6bf44eff19351))

## [0.2.0](https://github.com/Assetera-AG/AsseteraEvmContracts/compare/evm-contracts-v0.1.0...evm-contracts-v0.2.0) (2026-07-08)


### Features

* **script:** deterministic CreateX/CREATE3 deploy + CAIP-2 artifact (AC-249, phase 2) ([#7](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/7)) ([f81fc3a](https://github.com/Assetera-AG/AsseteraEvmContracts/commit/f81fc3a266df126bb6fa90317030727956d2916e))
* **sdk:** wagmi/cli codegen — ABIs, addresses, viem client, hooks (AC-249, phase 3) ([#11](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/11)) ([91b0c59](https://github.com/Assetera-AG/AsseteraEvmContracts/commit/91b0c599c027838e82bfe53fb7c460e0dee7e54d))


### Refactors

* ac 244 consolidate cancel order ([#15](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/15)) ([0221485](https://github.com/Assetera-AG/AsseteraEvmContracts/commit/02214857e8416e385fbe3685f37f3026883b68e7))
* ac 245 remove account blacklist ([#17](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/17)) ([8e9a4bd](https://github.com/Assetera-AG/AsseteraEvmContracts/commit/8e9a4bd82ec1234ea3f7ffae94e8410e091442bb))
* **repo:** monorepo restructure + SDK scaffold (AC-249, phase 1) ([#6](https://github.com/Assetera-AG/AsseteraEvmContracts/issues/6)) ([bd6027a](https://github.com/Assetera-AG/AsseteraEvmContracts/commit/bd6027a4cc23ccd52ce2d3b4b0ed883f7d9a9fbc))
