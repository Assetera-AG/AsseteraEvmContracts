# Changelog

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
