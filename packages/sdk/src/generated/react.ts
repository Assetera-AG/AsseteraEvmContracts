import {
  createUseReadContract,
  createUseWriteContract,
  createUseSimulateContract,
  createUseWatchContractEvent,
} from 'wagmi/codegen'

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// AsseteraECS
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const asseteraEcsAbi = [
  {
    type: 'constructor',
    inputs: [
      { name: 'trustedForwarder', internalType: 'address', type: 'address' },
    ],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [],
    name: 'DEFAULT_ADMIN_ROLE',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'FEE_OPERATOR_ROLE',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'FEE_TYPEHASH',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'KYC_OPERATOR_ROLE',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'KYC_TYPEHASH',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'MAX_FEE_BPS',
    outputs: [{ name: '', internalType: 'uint16', type: 'uint16' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'MAX_FEE_TTL',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'MAX_KYC_TTL',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'UPGRADE_INTERFACE_VERSION',
    outputs: [{ name: '', internalType: 'string', type: 'string' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'offerId', internalType: 'uint256', type: 'uint256' },
      {
        name: 'att',
        internalType: 'struct GateTypes.KycAttestation',
        type: 'tuple',
        components: [
          { name: 'account', internalType: 'address', type: 'address' },
          { name: 'action', internalType: 'uint8', type: 'uint8' },
          { name: 'orderId', internalType: 'uint256', type: 'uint256' },
          { name: 'nonce', internalType: 'uint256', type: 'uint256' },
          { name: 'deadline', internalType: 'uint256', type: 'uint256' },
          { name: 'paramsHash', internalType: 'bytes32', type: 'bytes32' },
          { name: 'signature', internalType: 'bytes', type: 'bytes' },
        ],
      },
    ],
    name: 'acceptOffer',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [{ name: 'collector', internalType: 'address', type: 'address' }],
    name: 'allowedCollectors',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'offerId', internalType: 'uint256', type: 'uint256' },
      {
        name: 'att',
        internalType: 'struct GateTypes.KycAttestation',
        type: 'tuple',
        components: [
          { name: 'account', internalType: 'address', type: 'address' },
          { name: 'action', internalType: 'uint8', type: 'uint8' },
          { name: 'orderId', internalType: 'uint256', type: 'uint256' },
          { name: 'nonce', internalType: 'uint256', type: 'uint256' },
          { name: 'deadline', internalType: 'uint256', type: 'uint256' },
          { name: 'paramsHash', internalType: 'bytes32', type: 'bytes32' },
          { name: 'signature', internalType: 'bytes', type: 'bytes' },
        ],
      },
    ],
    name: 'cancelOffer',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'offerId', internalType: 'uint256', type: 'uint256' },
      { name: 'makerRecipient', internalType: 'address', type: 'address' },
      { name: 'takerRecipient', internalType: 'address', type: 'address' },
    ],
    name: 'cancelOfferForUser',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [{ name: 'id', internalType: 'uint256', type: 'uint256' }],
    name: 'cancelOrder',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'id', internalType: 'uint256', type: 'uint256' },
      { name: 'recipient', internalType: 'address', type: 'address' },
    ],
    name: 'cancelOrderForUser',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [{ name: 'action', internalType: 'uint8', type: 'uint8' }],
    name: 'complianceRequired',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'eip712Domain',
    outputs: [
      { name: 'fields', internalType: 'bytes1', type: 'bytes1' },
      { name: 'name', internalType: 'string', type: 'string' },
      { name: 'version', internalType: 'string', type: 'string' },
      { name: 'chainId', internalType: 'uint256', type: 'uint256' },
      { name: 'verifyingContract', internalType: 'address', type: 'address' },
      { name: 'salt', internalType: 'bytes32', type: 'bytes32' },
      { name: 'extensions', internalType: 'uint256[]', type: 'uint256[]' },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'id', internalType: 'uint256', type: 'uint256' },
      { name: 'fillSellAmount', internalType: 'uint256', type: 'uint256' },
      {
        name: 'att',
        internalType: 'struct GateTypes.KycAttestation',
        type: 'tuple',
        components: [
          { name: 'account', internalType: 'address', type: 'address' },
          { name: 'action', internalType: 'uint8', type: 'uint8' },
          { name: 'orderId', internalType: 'uint256', type: 'uint256' },
          { name: 'nonce', internalType: 'uint256', type: 'uint256' },
          { name: 'deadline', internalType: 'uint256', type: 'uint256' },
          { name: 'paramsHash', internalType: 'bytes32', type: 'bytes32' },
          { name: 'signature', internalType: 'bytes', type: 'bytes' },
        ],
      },
    ],
    name: 'fillOrder',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [{ name: 'id', internalType: 'uint256', type: 'uint256' }],
    name: 'getOffer',
    outputs: [
      {
        name: '',
        internalType: 'struct ExchangeTypes.Offer',
        type: 'tuple',
        components: [
          { name: 'id', internalType: 'uint256', type: 'uint256' },
          { name: 'maker', internalType: 'address', type: 'address' },
          { name: 'taker', internalType: 'address', type: 'address' },
          { name: 'makerToken', internalType: 'address', type: 'address' },
          { name: 'makerAmount', internalType: 'uint256', type: 'uint256' },
          { name: 'takerToken', internalType: 'address', type: 'address' },
          { name: 'takerAmount', internalType: 'uint256', type: 'uint256' },
          {
            name: 'status',
            internalType: 'enum ExchangeTypes.OfferStatus',
            type: 'uint8',
          },
          { name: 'createdAt', internalType: 'uint64', type: 'uint64' },
          { name: 'expireTs', internalType: 'uint64', type: 'uint64' },
          { name: 'proposedBy', internalType: 'address', type: 'address' },
          { name: 'makerFeeBps', internalType: 'uint16', type: 'uint16' },
          { name: 'takerFeeBps', internalType: 'uint16', type: 'uint16' },
          { name: 'feeCollector', internalType: 'address', type: 'address' },
          { name: 'feeToken', internalType: 'address', type: 'address' },
          { name: 'escrowedFee', internalType: 'uint256', type: 'uint256' },
          { name: 'orderId', internalType: 'uint256', type: 'uint256' },
        ],
      },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [{ name: 'id', internalType: 'uint256', type: 'uint256' }],
    name: 'getOrder',
    outputs: [
      {
        name: '',
        internalType: 'struct ExchangeTypes.Order',
        type: 'tuple',
        components: [
          { name: 'id', internalType: 'uint256', type: 'uint256' },
          { name: 'maker', internalType: 'address', type: 'address' },
          { name: 'sellToken', internalType: 'address', type: 'address' },
          { name: 'sellAmount', internalType: 'uint256', type: 'uint256' },
          { name: 'buyToken', internalType: 'address', type: 'address' },
          { name: 'buyAmount', internalType: 'uint256', type: 'uint256' },
          {
            name: 'status',
            internalType: 'enum ExchangeTypes.OrderStatus',
            type: 'uint8',
          },
          { name: 'createdAt', internalType: 'uint64', type: 'uint64' },
          {
            name: 'remainingQuantity',
            internalType: 'uint256',
            type: 'uint256',
          },
          { name: 'expireTs', internalType: 'uint64', type: 'uint64' },
          { name: 'makerFeeBps', internalType: 'uint16', type: 'uint16' },
          { name: 'takerFeeBps', internalType: 'uint16', type: 'uint16' },
          { name: 'feeCollector', internalType: 'address', type: 'address' },
          { name: 'feeToken', internalType: 'address', type: 'address' },
          { name: 'escrowedFee', internalType: 'uint256', type: 'uint256' },
          { name: 'boughtQuantity', internalType: 'uint256', type: 'uint256' },
        ],
      },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [{ name: 'role', internalType: 'bytes32', type: 'bytes32' }],
    name: 'getRoleAdmin',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'role', internalType: 'bytes32', type: 'bytes32' },
      { name: 'account', internalType: 'address', type: 'address' },
    ],
    name: 'grantRole',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'role', internalType: 'bytes32', type: 'bytes32' },
      { name: 'account', internalType: 'address', type: 'address' },
    ],
    name: 'hasRole',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'admin', internalType: 'address', type: 'address' },
      { name: 'kycSigner', internalType: 'address', type: 'address' },
      { name: 'feeSigner', internalType: 'address', type: 'address' },
    ],
    name: 'initialize',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [{ name: 'forwarder', internalType: 'address', type: 'address' }],
    name: 'isTrustedForwarder',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'orderId', internalType: 'uint256', type: 'uint256' },
      { name: 'taker', internalType: 'address', type: 'address' },
      { name: 'makerToken', internalType: 'address', type: 'address' },
      { name: 'makerAmount', internalType: 'uint256', type: 'uint256' },
      { name: 'takerToken', internalType: 'address', type: 'address' },
      { name: 'takerAmount', internalType: 'uint256', type: 'uint256' },
      { name: 'expireTs', internalType: 'uint64', type: 'uint64' },
      {
        name: 'att',
        internalType: 'struct GateTypes.KycAttestation',
        type: 'tuple',
        components: [
          { name: 'account', internalType: 'address', type: 'address' },
          { name: 'action', internalType: 'uint8', type: 'uint8' },
          { name: 'orderId', internalType: 'uint256', type: 'uint256' },
          { name: 'nonce', internalType: 'uint256', type: 'uint256' },
          { name: 'deadline', internalType: 'uint256', type: 'uint256' },
          { name: 'paramsHash', internalType: 'bytes32', type: 'bytes32' },
          { name: 'signature', internalType: 'bytes', type: 'bytes' },
        ],
      },
      {
        name: 'feeAtt',
        internalType: 'struct GateTypes.FeeAttestation',
        type: 'tuple',
        components: [
          { name: 'account', internalType: 'address', type: 'address' },
          { name: 'action', internalType: 'uint8', type: 'uint8' },
          { name: 'nonce', internalType: 'uint256', type: 'uint256' },
          { name: 'deadline', internalType: 'uint256', type: 'uint256' },
          { name: 'paramsHash', internalType: 'bytes32', type: 'bytes32' },
          { name: 'makerFeeBps', internalType: 'uint16', type: 'uint16' },
          { name: 'takerFeeBps', internalType: 'uint16', type: 'uint16' },
          { name: 'feeCollector', internalType: 'address', type: 'address' },
          { name: 'feeToken', internalType: 'address', type: 'address' },
          { name: 'signature', internalType: 'bytes', type: 'bytes' },
        ],
      },
    ],
    name: 'makeOffer',
    outputs: [{ name: 'id', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [],
    name: 'pause',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [],
    name: 'paused',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'token', internalType: 'address', type: 'address' },
      { name: 'value', internalType: 'uint256', type: 'uint256' },
      { name: 'deadline', internalType: 'uint256', type: 'uint256' },
      { name: 'v', internalType: 'uint8', type: 'uint8' },
      { name: 'r', internalType: 'bytes32', type: 'bytes32' },
      { name: 's', internalType: 'bytes32', type: 'bytes32' },
      { name: 'data', internalType: 'bytes', type: 'bytes' },
    ],
    name: 'permitAndCall',
    outputs: [
      { name: 'permitAccepted', internalType: 'bool', type: 'bool' },
      { name: 'result', internalType: 'bytes', type: 'bytes' },
    ],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'sellToken', internalType: 'address', type: 'address' },
      { name: 'sellAmount', internalType: 'uint256', type: 'uint256' },
      { name: 'buyToken', internalType: 'address', type: 'address' },
      { name: 'buyAmount', internalType: 'uint256', type: 'uint256' },
      { name: 'expireTs', internalType: 'uint64', type: 'uint64' },
      {
        name: 'att',
        internalType: 'struct GateTypes.KycAttestation',
        type: 'tuple',
        components: [
          { name: 'account', internalType: 'address', type: 'address' },
          { name: 'action', internalType: 'uint8', type: 'uint8' },
          { name: 'orderId', internalType: 'uint256', type: 'uint256' },
          { name: 'nonce', internalType: 'uint256', type: 'uint256' },
          { name: 'deadline', internalType: 'uint256', type: 'uint256' },
          { name: 'paramsHash', internalType: 'bytes32', type: 'bytes32' },
          { name: 'signature', internalType: 'bytes', type: 'bytes' },
        ],
      },
      {
        name: 'feeAtt',
        internalType: 'struct GateTypes.FeeAttestation',
        type: 'tuple',
        components: [
          { name: 'account', internalType: 'address', type: 'address' },
          { name: 'action', internalType: 'uint8', type: 'uint8' },
          { name: 'nonce', internalType: 'uint256', type: 'uint256' },
          { name: 'deadline', internalType: 'uint256', type: 'uint256' },
          { name: 'paramsHash', internalType: 'bytes32', type: 'bytes32' },
          { name: 'makerFeeBps', internalType: 'uint16', type: 'uint16' },
          { name: 'takerFeeBps', internalType: 'uint16', type: 'uint16' },
          { name: 'feeCollector', internalType: 'address', type: 'address' },
          { name: 'feeToken', internalType: 'address', type: 'address' },
          { name: 'signature', internalType: 'bytes', type: 'bytes' },
        ],
      },
    ],
    name: 'placeOrder',
    outputs: [{ name: 'id', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'sellToken', internalType: 'address', type: 'address' },
      { name: 'sellAmount', internalType: 'uint256', type: 'uint256' },
      { name: 'buyToken', internalType: 'address', type: 'address' },
      { name: 'buyAmount', internalType: 'uint256', type: 'uint256' },
      { name: 'expireTs', internalType: 'uint64', type: 'uint64' },
      { name: 'permitDeadline', internalType: 'uint256', type: 'uint256' },
      { name: 'v', internalType: 'uint8', type: 'uint8' },
      { name: 'r', internalType: 'bytes32', type: 'bytes32' },
      { name: 's', internalType: 'bytes32', type: 'bytes32' },
      {
        name: 'att',
        internalType: 'struct GateTypes.KycAttestation',
        type: 'tuple',
        components: [
          { name: 'account', internalType: 'address', type: 'address' },
          { name: 'action', internalType: 'uint8', type: 'uint8' },
          { name: 'orderId', internalType: 'uint256', type: 'uint256' },
          { name: 'nonce', internalType: 'uint256', type: 'uint256' },
          { name: 'deadline', internalType: 'uint256', type: 'uint256' },
          { name: 'paramsHash', internalType: 'bytes32', type: 'bytes32' },
          { name: 'signature', internalType: 'bytes', type: 'bytes' },
        ],
      },
      {
        name: 'feeAtt',
        internalType: 'struct GateTypes.FeeAttestation',
        type: 'tuple',
        components: [
          { name: 'account', internalType: 'address', type: 'address' },
          { name: 'action', internalType: 'uint8', type: 'uint8' },
          { name: 'nonce', internalType: 'uint256', type: 'uint256' },
          { name: 'deadline', internalType: 'uint256', type: 'uint256' },
          { name: 'paramsHash', internalType: 'bytes32', type: 'bytes32' },
          { name: 'makerFeeBps', internalType: 'uint16', type: 'uint16' },
          { name: 'takerFeeBps', internalType: 'uint16', type: 'uint16' },
          { name: 'feeCollector', internalType: 'address', type: 'address' },
          { name: 'feeToken', internalType: 'address', type: 'address' },
          { name: 'signature', internalType: 'bytes', type: 'bytes' },
        ],
      },
    ],
    name: 'placeOrderWithPermit',
    outputs: [{ name: 'id', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [],
    name: 'proxiableUUID',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'role', internalType: 'bytes32', type: 'bytes32' },
      { name: 'callerConfirmation', internalType: 'address', type: 'address' },
    ],
    name: 'renounceRole',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'offerId', internalType: 'uint256', type: 'uint256' },
      { name: 'newMakerAmount', internalType: 'uint256', type: 'uint256' },
      { name: 'newTakerAmount', internalType: 'uint256', type: 'uint256' },
      { name: 'expireTs', internalType: 'uint64', type: 'uint64' },
      {
        name: 'att',
        internalType: 'struct GateTypes.KycAttestation',
        type: 'tuple',
        components: [
          { name: 'account', internalType: 'address', type: 'address' },
          { name: 'action', internalType: 'uint8', type: 'uint8' },
          { name: 'orderId', internalType: 'uint256', type: 'uint256' },
          { name: 'nonce', internalType: 'uint256', type: 'uint256' },
          { name: 'deadline', internalType: 'uint256', type: 'uint256' },
          { name: 'paramsHash', internalType: 'bytes32', type: 'bytes32' },
          { name: 'signature', internalType: 'bytes', type: 'bytes' },
        ],
      },
    ],
    name: 'replaceOffer',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'role', internalType: 'bytes32', type: 'bytes32' },
      { name: 'account', internalType: 'address', type: 'address' },
    ],
    name: 'revokeRole',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'collector', internalType: 'address', type: 'address' },
      { name: 'allowed', internalType: 'bool', type: 'bool' },
    ],
    name: 'setAllowedCollector',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      {
        name: 'action',
        internalType: 'enum ExchangeTypes.Action',
        type: 'uint8',
      },
      { name: 'required', internalType: 'bool', type: 'bool' },
    ],
    name: 'setComplianceRequired',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [{ name: 'interfaceId', internalType: 'bytes4', type: 'bytes4' }],
    name: 'supportsInterface',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [{ name: 'ids', internalType: 'uint256[]', type: 'uint256[]' }],
    name: 'sweepExpired',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [{ name: 'ids', internalType: 'uint256[]', type: 'uint256[]' }],
    name: 'sweepExpiredOffers',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [],
    name: 'totalOffers',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'totalOrders',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'trustedForwarder',
    outputs: [{ name: '', internalType: 'address', type: 'address' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'unpause',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'newImplementation', internalType: 'address', type: 'address' },
      { name: 'data', internalType: 'bytes', type: 'bytes' },
    ],
    name: 'upgradeToAndCall',
    outputs: [],
    stateMutability: 'payable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'account', internalType: 'address', type: 'address' },
      { name: 'nonce', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'usedFeeNonce',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'account', internalType: 'address', type: 'address' },
      { name: 'nonce', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'usedNonce',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'version',
    outputs: [{ name: '', internalType: 'string', type: 'string' }],
    stateMutability: 'pure',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'collector',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      { name: 'allowed', internalType: 'bool', type: 'bool', indexed: false },
    ],
    name: 'CollectorAllowed',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'action',
        internalType: 'enum ExchangeTypes.Action',
        type: 'uint8',
        indexed: true,
      },
      { name: 'required', internalType: 'bool', type: 'bool', indexed: false },
    ],
    name: 'ComplianceRequiredSet',
  },
  { type: 'event', anonymous: false, inputs: [], name: 'EIP712DomainChanged' },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'account',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      { name: 'action', internalType: 'uint8', type: 'uint8', indexed: true },
      {
        name: 'nonce',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'FeeConsumed',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'version',
        internalType: 'uint64',
        type: 'uint64',
        indexed: false,
      },
    ],
    name: 'Initialized',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'account',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      { name: 'action', internalType: 'uint8', type: 'uint8', indexed: true },
      {
        name: 'orderId',
        internalType: 'uint256',
        type: 'uint256',
        indexed: true,
      },
      {
        name: 'nonce',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'KycConsumed',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'id', internalType: 'uint256', type: 'uint256', indexed: true },
      { name: 'by', internalType: 'address', type: 'address', indexed: true },
      {
        name: 'makerAmount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'takerAmount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'orderId',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'OfferAccepted',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'id', internalType: 'uint256', type: 'uint256', indexed: true },
      { name: 'by', internalType: 'address', type: 'address', indexed: true },
      {
        name: 'makerAmount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'takerAmount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'OfferCancelled',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'id', internalType: 'uint256', type: 'uint256', indexed: true },
      {
        name: 'proposedBy',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'amountReturned',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'OfferExpired',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'id', internalType: 'uint256', type: 'uint256', indexed: true },
      {
        name: 'maker',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'makerRecipient',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
      {
        name: 'takerRecipient',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
      {
        name: 'admin',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
    ],
    name: 'OfferForceCancelled',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'id', internalType: 'uint256', type: 'uint256', indexed: true },
      {
        name: 'maker',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'taker',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'makerToken',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
      {
        name: 'makerAmount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'takerToken',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
      {
        name: 'takerAmount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'expireTs',
        internalType: 'uint64',
        type: 'uint64',
        indexed: false,
      },
      {
        name: 'makerFeeBps',
        internalType: 'uint16',
        type: 'uint16',
        indexed: false,
      },
      {
        name: 'takerFeeBps',
        internalType: 'uint16',
        type: 'uint16',
        indexed: false,
      },
      {
        name: 'feeCollector',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
      {
        name: 'feeToken',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
      {
        name: 'orderId',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'OfferMade',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'id', internalType: 'uint256', type: 'uint256', indexed: true },
      { name: 'by', internalType: 'address', type: 'address', indexed: true },
      {
        name: 'newMakerAmount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'newTakerAmount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'expireTs',
        internalType: 'uint64',
        type: 'uint64',
        indexed: false,
      },
    ],
    name: 'OfferReplaced',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'id', internalType: 'uint256', type: 'uint256', indexed: true },
      { name: 'by', internalType: 'address', type: 'address', indexed: true },
      {
        name: 'makerAmountGross',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'takerAmountGross',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'makerFeeAmount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'takerFeeAmount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'feeCollector',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
      {
        name: 'feeToken',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
    ],
    name: 'OfferSettled',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'id', internalType: 'uint256', type: 'uint256', indexed: true },
      {
        name: 'maker',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'refunded',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'OrderCancelled',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'orderId',
        internalType: 'uint256',
        type: 'uint256',
        indexed: true,
      },
      {
        name: 'offerId',
        internalType: 'uint256',
        type: 'uint256',
        indexed: true,
      },
      {
        name: 'refunded',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'OrderClosedByOffer',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'orderId',
        internalType: 'uint256',
        type: 'uint256',
        indexed: true,
      },
      {
        name: 'offerId',
        internalType: 'uint256',
        type: 'uint256',
        indexed: true,
      },
      {
        name: 'drawn',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'remainingQuantity',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'OrderEscrowDrawn',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'id', internalType: 'uint256', type: 'uint256', indexed: true },
      {
        name: 'maker',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'refunded',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'OrderExpired',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'id', internalType: 'uint256', type: 'uint256', indexed: true },
      {
        name: 'maker',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'taker',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'filledSellAmount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'filledBuyAmount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'makerFeeAmount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'takerFeeAmount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'feeCollector',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
      {
        name: 'feeToken',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
    ],
    name: 'OrderFilled',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'id', internalType: 'uint256', type: 'uint256', indexed: true },
      {
        name: 'maker',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'recipient',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
      {
        name: 'admin',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
    ],
    name: 'OrderForceCancelled',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'id', internalType: 'uint256', type: 'uint256', indexed: true },
      {
        name: 'maker',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'taker',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'filledSellAmount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'filledBuyAmount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'remainingQuantity',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'makerFeeAmount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'takerFeeAmount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'feeCollector',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
      {
        name: 'feeToken',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
    ],
    name: 'OrderPartiallyFilled',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'id', internalType: 'uint256', type: 'uint256', indexed: true },
      {
        name: 'maker',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'sellToken',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
      {
        name: 'sellAmount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'buyToken',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
      {
        name: 'buyAmount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'expireTs',
        internalType: 'uint64',
        type: 'uint64',
        indexed: false,
      },
      {
        name: 'makerFeeBps',
        internalType: 'uint16',
        type: 'uint16',
        indexed: false,
      },
      {
        name: 'takerFeeBps',
        internalType: 'uint16',
        type: 'uint16',
        indexed: false,
      },
      {
        name: 'feeCollector',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
      {
        name: 'feeToken',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
    ],
    name: 'OrderPlaced',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'account',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
    ],
    name: 'Paused',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'role', internalType: 'bytes32', type: 'bytes32', indexed: true },
      {
        name: 'previousAdminRole',
        internalType: 'bytes32',
        type: 'bytes32',
        indexed: true,
      },
      {
        name: 'newAdminRole',
        internalType: 'bytes32',
        type: 'bytes32',
        indexed: true,
      },
    ],
    name: 'RoleAdminChanged',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'role', internalType: 'bytes32', type: 'bytes32', indexed: true },
      {
        name: 'account',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'sender',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
    ],
    name: 'RoleGranted',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'role', internalType: 'bytes32', type: 'bytes32', indexed: true },
      {
        name: 'account',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'sender',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
    ],
    name: 'RoleRevoked',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'account',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
    ],
    name: 'Unpaused',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'implementation',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
    ],
    name: 'Upgraded',
  },
  {
    type: 'error',
    inputs: [{ name: 'id', internalType: 'uint256', type: 'uint256' }],
    name: 'AcceptorIsProposer',
  },
  { type: 'error', inputs: [], name: 'AccessControlBadConfirmation' },
  {
    type: 'error',
    inputs: [
      { name: 'account', internalType: 'address', type: 'address' },
      { name: 'neededRole', internalType: 'bytes32', type: 'bytes32' },
    ],
    name: 'AccessControlUnauthorizedAccount',
  },
  {
    type: 'error',
    inputs: [{ name: 'target', internalType: 'address', type: 'address' }],
    name: 'AddressEmptyCode',
  },
  { type: 'error', inputs: [], name: 'ECDSAInvalidSignature' },
  {
    type: 'error',
    inputs: [{ name: 'length', internalType: 'uint256', type: 'uint256' }],
    name: 'ECDSAInvalidSignatureLength',
  },
  {
    type: 'error',
    inputs: [{ name: 's', internalType: 'bytes32', type: 'bytes32' }],
    name: 'ECDSAInvalidSignatureS',
  },
  {
    type: 'error',
    inputs: [
      { name: 'implementation', internalType: 'address', type: 'address' },
    ],
    name: 'ERC1967InvalidImplementation',
  },
  { type: 'error', inputs: [], name: 'ERC1967NonPayable' },
  { type: 'error', inputs: [], name: 'EnforcedPause' },
  { type: 'error', inputs: [], name: 'ExpectedPause' },
  { type: 'error', inputs: [], name: 'FailedCall' },
  { type: 'error', inputs: [], name: 'FeeAccountMismatch' },
  { type: 'error', inputs: [], name: 'FeeActionMismatch' },
  { type: 'error', inputs: [], name: 'FeeBadSigner' },
  {
    type: 'error',
    inputs: [{ name: 'collector', internalType: 'address', type: 'address' }],
    name: 'FeeCollectorNotAllowed',
  },
  { type: 'error', inputs: [], name: 'FeeExpired' },
  { type: 'error', inputs: [], name: 'FeeNonceUsed' },
  {
    type: 'error',
    inputs: [{ name: 'feeToken', internalType: 'address', type: 'address' }],
    name: 'FeeTokenNotALeg',
  },
  { type: 'error', inputs: [], name: 'FeeTtlTooLong' },
  { type: 'error', inputs: [], name: 'FillAmountZero' },
  {
    type: 'error',
    inputs: [
      { name: 'id', internalType: 'uint256', type: 'uint256' },
      { name: 'remaining', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'FillExceedsRemaining',
  },
  { type: 'error', inputs: [], name: 'InvalidExpiry' },
  { type: 'error', inputs: [], name: 'InvalidFee' },
  { type: 'error', inputs: [], name: 'InvalidInitialization' },
  { type: 'error', inputs: [], name: 'KycAccountMismatch' },
  { type: 'error', inputs: [], name: 'KycActionMismatch' },
  { type: 'error', inputs: [], name: 'KycBadSigner' },
  { type: 'error', inputs: [], name: 'KycExpired' },
  { type: 'error', inputs: [], name: 'KycNonceUsed' },
  { type: 'error', inputs: [], name: 'KycOrderMismatch' },
  { type: 'error', inputs: [], name: 'KycTtlTooLong' },
  {
    type: 'error',
    inputs: [{ name: 'id', internalType: 'uint256', type: 'uint256' }],
    name: 'LegacyOfferMustBeUnwound',
  },
  {
    type: 'error',
    inputs: [{ name: 'id', internalType: 'uint256', type: 'uint256' }],
    name: 'LegacyOrderMustBeUnwound',
  },
  { type: 'error', inputs: [], name: 'NotInitializing' },
  {
    type: 'error',
    inputs: [{ name: 'id', internalType: 'uint256', type: 'uint256' }],
    name: 'NotMaker',
  },
  {
    type: 'error',
    inputs: [{ name: 'id', internalType: 'uint256', type: 'uint256' }],
    name: 'NotOfferParty',
  },
  {
    type: 'error',
    inputs: [{ name: 'id', internalType: 'uint256', type: 'uint256' }],
    name: 'OfferIsExpired',
  },
  {
    type: 'error',
    inputs: [{ name: 'id', internalType: 'uint256', type: 'uint256' }],
    name: 'OfferNotFound',
  },
  {
    type: 'error',
    inputs: [{ name: 'id', internalType: 'uint256', type: 'uint256' }],
    name: 'OfferNotOpen',
  },
  { type: 'error', inputs: [], name: 'OfferSelfTarget' },
  {
    type: 'error',
    inputs: [{ name: 'id', internalType: 'uint256', type: 'uint256' }],
    name: 'OrderIsExpired',
  },
  {
    type: 'error',
    inputs: [{ name: 'orderId', internalType: 'uint256', type: 'uint256' }],
    name: 'OrderNotLinkable',
  },
  {
    type: 'error',
    inputs: [{ name: 'id', internalType: 'uint256', type: 'uint256' }],
    name: 'OrderNotOpen',
  },
  { type: 'error', inputs: [], name: 'ParamsHashMismatch' },
  { type: 'error', inputs: [], name: 'ReentrancyGuardReentrantCall' },
  {
    type: 'error',
    inputs: [{ name: 'token', internalType: 'address', type: 'address' }],
    name: 'SafeERC20FailedOperation',
  },
  { type: 'error', inputs: [], name: 'SameToken' },
  {
    type: 'error',
    inputs: [{ name: 'id', internalType: 'uint256', type: 'uint256' }],
    name: 'SelfTrade',
  },
  { type: 'error', inputs: [], name: 'UUPSUnauthorizedCallContext' },
  {
    type: 'error',
    inputs: [{ name: 'slot', internalType: 'bytes32', type: 'bytes32' }],
    name: 'UUPSUnsupportedProxiableUUID',
  },
  { type: 'error', inputs: [], name: 'ZeroAddress' },
  { type: 'error', inputs: [], name: 'ZeroAmount' },
] as const

/**
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const asseteraEcsAddress = {
  1: '0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad',
  137: '0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad',
  80002: '0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad',
  11155111: '0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad',
} as const

/**
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const asseteraEcsConfig = {
  address: asseteraEcsAddress,
  abi: asseteraEcsAbi,
} as const

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// AsseteraIssuanceVenue
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

export const asseteraIssuanceVenueAbi = [
  {
    type: 'constructor',
    inputs: [
      {
        name: 'config',
        internalType: 'struct IAsseteraIssuanceVenue.SaleConfig',
        type: 'tuple',
        components: [
          { name: 'admin', internalType: 'address', type: 'address' },
          { name: 'rateSetter', internalType: 'address', type: 'address' },
          { name: 'pauser', internalType: 'address', type: 'address' },
          { name: 'treasurer', internalType: 'address', type: 'address' },
          { name: 'router', internalType: 'address', type: 'address' },
          { name: 'settlementToken', internalType: 'address', type: 'address' },
          { name: 'assetToken', internalType: 'address', type: 'address' },
          { name: 'unitPrice', internalType: 'uint256', type: 'uint256' },
          { name: 'minUnitPrice', internalType: 'uint256', type: 'uint256' },
          { name: 'maxUnitPrice', internalType: 'uint256', type: 'uint256' },
          {
            name: 'maxSettlementPerPurchaseWholeUnits',
            internalType: 'uint256',
            type: 'uint256',
          },
        ],
      },
    ],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [],
    name: 'ASSET_DECIMALS',
    outputs: [{ name: '', internalType: 'uint8', type: 'uint8' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'ASSET_TOKEN',
    outputs: [{ name: '', internalType: 'contract IERC20', type: 'address' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'ASSET_UNIT',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'DEFAULT_ADMIN_ROLE',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'MAX_TOKEN_DECIMALS',
    outputs: [{ name: '', internalType: 'uint8', type: 'uint8' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'MAX_UNIT_PRICE',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'MIN_UNIT_PRICE',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'PAUSER_ROLE',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'RATE_SETTER_ROLE',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'ROUTER',
    outputs: [{ name: '', internalType: 'address', type: 'address' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'SETTLEMENT_DECIMALS',
    outputs: [{ name: '', internalType: 'uint8', type: 'uint8' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'SETTLEMENT_TOKEN',
    outputs: [{ name: '', internalType: 'contract IERC20', type: 'address' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'TREASURY_ROLE',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [{ name: 'role', internalType: 'bytes32', type: 'bytes32' }],
    name: 'getRoleAdmin',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'role', internalType: 'bytes32', type: 'bytes32' },
      { name: 'account', internalType: 'address', type: 'address' },
    ],
    name: 'grantRole',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'role', internalType: 'bytes32', type: 'bytes32' },
      { name: 'account', internalType: 'address', type: 'address' },
    ],
    name: 'hasRole',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'maxSettlementPerPurchase',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'maxSettlementPerPurchaseWholeUnits',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'pause',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [],
    name: 'paused',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'buyer', internalType: 'address', type: 'address' },
      { name: 'settlementIn', internalType: 'uint256', type: 'uint256' },
      { name: 'minAssetOut', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'purchase',
    outputs: [
      { name: 'assetMinted', internalType: 'uint256', type: 'uint256' },
      { name: 'settlementCharged', internalType: 'uint256', type: 'uint256' },
    ],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'settlementIn', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'quoteAssetOut',
    outputs: [
      { name: 'assetOut', internalType: 'uint256', type: 'uint256' },
      { name: 'settlementCharged', internalType: 'uint256', type: 'uint256' },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [{ name: 'assetOut', internalType: 'uint256', type: 'uint256' }],
    name: 'quoteSettlementIn',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'role', internalType: 'bytes32', type: 'bytes32' },
      { name: 'callerConfirmation', internalType: 'address', type: 'address' },
    ],
    name: 'renounceRole',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'token', internalType: 'address', type: 'address' },
      { name: 'to', internalType: 'address', type: 'address' },
      { name: 'amount', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'rescue',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'role', internalType: 'bytes32', type: 'bytes32' },
      { name: 'account', internalType: 'address', type: 'address' },
    ],
    name: 'revokeRole',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [{ name: 'wholeUnits', internalType: 'uint256', type: 'uint256' }],
    name: 'setMaxSettlementPerPurchase',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'newUnitPrice', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'setUnitPrice',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [{ name: 'interfaceId', internalType: 'bytes4', type: 'bytes4' }],
    name: 'supportsInterface',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'unitPrice',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'unpause',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'to', internalType: 'address', type: 'address' },
      { name: 'amount', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'withdraw',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'buyer',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'assetToken',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'assetMinted',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'settlementToken',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
      {
        name: 'settlementIn',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'unitPrice',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'IssuanceMinted',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'account',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
    ],
    name: 'Paused',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'to', internalType: 'address', type: 'address', indexed: true },
      {
        name: 'amount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'ProceedsWithdrawn',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'wholeUnits',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'rawCap',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'decimals',
        internalType: 'uint8',
        type: 'uint8',
        indexed: false,
      },
    ],
    name: 'PurchaseCapSet',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'role', internalType: 'bytes32', type: 'bytes32', indexed: true },
      {
        name: 'previousAdminRole',
        internalType: 'bytes32',
        type: 'bytes32',
        indexed: true,
      },
      {
        name: 'newAdminRole',
        internalType: 'bytes32',
        type: 'bytes32',
        indexed: true,
      },
    ],
    name: 'RoleAdminChanged',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'role', internalType: 'bytes32', type: 'bytes32', indexed: true },
      {
        name: 'account',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'sender',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
    ],
    name: 'RoleGranted',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'role', internalType: 'bytes32', type: 'bytes32', indexed: true },
      {
        name: 'account',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'sender',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
    ],
    name: 'RoleRevoked',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'token',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      { name: 'to', internalType: 'address', type: 'address', indexed: true },
      {
        name: 'amount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'TokensRescued',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'previousUnitPrice',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'newUnitPrice',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'UnitPriceSet',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'account',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
    ],
    name: 'Unpaused',
  },
  { type: 'error', inputs: [], name: 'AccessControlBadConfirmation' },
  {
    type: 'error',
    inputs: [
      { name: 'account', internalType: 'address', type: 'address' },
      { name: 'neededRole', internalType: 'bytes32', type: 'bytes32' },
    ],
    name: 'AccessControlUnauthorizedAccount',
  },
  {
    type: 'error',
    inputs: [
      { name: 'delivered', internalType: 'uint256', type: 'uint256' },
      { name: 'expected', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'AssetDeliveryShortfall',
  },
  {
    type: 'error',
    inputs: [{ name: 'caller', internalType: 'address', type: 'address' }],
    name: 'CallerNotRouter',
  },
  {
    type: 'error',
    inputs: [
      { name: 'charged', internalType: 'uint256', type: 'uint256' },
      { name: 'authorised', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'ChargeExceedsAuthorised',
  },
  { type: 'error', inputs: [], name: 'EnforcedPause' },
  { type: 'error', inputs: [], name: 'ExpectedPause' },
  {
    type: 'error',
    inputs: [
      { name: 'assetOut', internalType: 'uint256', type: 'uint256' },
      { name: 'minAssetOut', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'InsufficientAssetOut',
  },
  {
    type: 'error',
    inputs: [
      { name: 'settlementIn', internalType: 'uint256', type: 'uint256' },
      { name: 'unitPrice', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'NothingToMint',
  },
  {
    type: 'error',
    inputs: [
      { name: 'minUnitPrice', internalType: 'uint256', type: 'uint256' },
      { name: 'maxUnitPrice', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'PriceBoundsInvalid',
  },
  {
    type: 'error',
    inputs: [
      { name: 'settlementIn', internalType: 'uint256', type: 'uint256' },
      { name: 'cap', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'PurchaseCapExceeded',
  },
  { type: 'error', inputs: [], name: 'ReentrancyGuardReentrantCall' },
  { type: 'error', inputs: [], name: 'RescueOfSettlementToken' },
  {
    type: 'error',
    inputs: [{ name: 'token', internalType: 'address', type: 'address' }],
    name: 'SafeERC20FailedOperation',
  },
  { type: 'error', inputs: [], name: 'SameToken' },
  {
    type: 'error',
    inputs: [
      { name: 'requested', internalType: 'uint256', type: 'uint256' },
      { name: 'received', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'SettlementPullMismatch',
  },
  {
    type: 'error',
    inputs: [
      { name: 'token', internalType: 'address', type: 'address' },
      { name: 'decimals', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'TokenDecimalsImplausible',
  },
  {
    type: 'error',
    inputs: [
      { name: 'unitPrice', internalType: 'uint256', type: 'uint256' },
      { name: 'minUnitPrice', internalType: 'uint256', type: 'uint256' },
      { name: 'maxUnitPrice', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'UnitPriceOutOfBounds',
  },
  { type: 'error', inputs: [], name: 'ZeroAddress' },
  { type: 'error', inputs: [], name: 'ZeroAmount' },
] as const

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// AsseteraPrimarySales
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const asseteraPrimarySalesAbi = [
  {
    type: 'constructor',
    inputs: [
      { name: 'trustedForwarder', internalType: 'address', type: 'address' },
    ],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [],
    name: 'DEFAULT_ADMIN_ROLE',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'FEE_OPERATOR_ROLE',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'FEE_TYPEHASH',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'INTENT_TYPEHASH',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'KYC_OPERATOR_ROLE',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'KYC_TYPEHASH',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'MAX_FEE_BPS',
    outputs: [{ name: '', internalType: 'uint16', type: 'uint16' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'MAX_FEE_TTL',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'MAX_INTENT_TTL',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'MAX_KYC_TTL',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'MAX_SETTLEMENT_TOKEN_DECIMALS',
    outputs: [{ name: '', internalType: 'uint8', type: 'uint8' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'REDEMPTION_TYPEHASH',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'SETTLEMENT_OPERATOR_ROLE',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'UPGRADE_INTERFACE_VERSION',
    outputs: [{ name: '', internalType: 'string', type: 'string' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [{ name: 'collector', internalType: 'address', type: 'address' }],
    name: 'allowedCollectors',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [{ name: 'action', internalType: 'uint8', type: 'uint8' }],
    name: 'complianceRequired',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'eip712Domain',
    outputs: [
      { name: 'fields', internalType: 'bytes1', type: 'bytes1' },
      { name: 'name', internalType: 'string', type: 'string' },
      { name: 'version', internalType: 'string', type: 'string' },
      { name: 'chainId', internalType: 'uint256', type: 'uint256' },
      { name: 'verifyingContract', internalType: 'address', type: 'address' },
      { name: 'salt', internalType: 'bytes32', type: 'bytes32' },
      { name: 'extensions', internalType: 'uint256[]', type: 'uint256[]' },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [{ name: 'role', internalType: 'bytes32', type: 'bytes32' }],
    name: 'getRoleAdmin',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'role', internalType: 'bytes32', type: 'bytes32' },
      { name: 'account', internalType: 'address', type: 'address' },
    ],
    name: 'grantRole',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'role', internalType: 'bytes32', type: 'bytes32' },
      { name: 'account', internalType: 'address', type: 'address' },
    ],
    name: 'hasRole',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'admin', internalType: 'address', type: 'address' },
      { name: 'kycSigner', internalType: 'address', type: 'address' },
      { name: 'feeSigner', internalType: 'address', type: 'address' },
      { name: 'settlementSigner', internalType: 'address', type: 'address' },
    ],
    name: 'initialize',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [{ name: 'forwarder', internalType: 'address', type: 'address' }],
    name: 'isTrustedForwarder',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'pause',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [],
    name: 'paused',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [{ name: 'token', internalType: 'address', type: 'address' }],
    name: 'perTxCap',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [{ name: 'token', internalType: 'address', type: 'address' }],
    name: 'perTxCapWholeUnits',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'token', internalType: 'address', type: 'address' },
      { name: 'value', internalType: 'uint256', type: 'uint256' },
      { name: 'deadline', internalType: 'uint256', type: 'uint256' },
      { name: 'v', internalType: 'uint8', type: 'uint8' },
      { name: 'r', internalType: 'bytes32', type: 'bytes32' },
      { name: 's', internalType: 'bytes32', type: 'bytes32' },
      { name: 'data', internalType: 'bytes', type: 'bytes' },
    ],
    name: 'permitAndCall',
    outputs: [
      { name: 'permitAccepted', internalType: 'bool', type: 'bool' },
      { name: 'result', internalType: 'bytes', type: 'bytes' },
    ],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [],
    name: 'proxiableUUID',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'venueCalldata', internalType: 'bytes', type: 'bytes' },
      {
        name: 'intent',
        internalType: 'struct PrimaryTypes.RedemptionIntent',
        type: 'tuple',
        components: [
          { name: 'seller', internalType: 'address', type: 'address' },
          { name: 'assetToken', internalType: 'address', type: 'address' },
          { name: 'accountingMode', internalType: 'uint8', type: 'uint8' },
          { name: 'maxAssetIn', internalType: 'uint256', type: 'uint256' },
          { name: 'settlementToken', internalType: 'address', type: 'address' },
          { name: 'venueQuoteOut', internalType: 'uint256', type: 'uint256' },
          { name: 'sellerFee', internalType: 'uint256', type: 'uint256' },
          {
            name: 'minSettlementOut',
            internalType: 'uint256',
            type: 'uint256',
          },
          { name: 'feeCollector', internalType: 'address', type: 'address' },
          { name: 'venue', internalType: 'address', type: 'address' },
          { name: 'selector', internalType: 'bytes4', type: 'bytes4' },
          { name: 'calldataHash', internalType: 'bytes32', type: 'bytes32' },
          {
            name: 'supplierReference',
            internalType: 'bytes32',
            type: 'bytes32',
          },
          { name: 'nonce', internalType: 'uint256', type: 'uint256' },
          { name: 'deadline', internalType: 'uint256', type: 'uint256' },
        ],
      },
      { name: 'intentSignature', internalType: 'bytes', type: 'bytes' },
      { name: 'sellerSignature', internalType: 'bytes', type: 'bytes' },
      {
        name: 'kyc',
        internalType: 'struct GateTypes.KycAttestation',
        type: 'tuple',
        components: [
          { name: 'account', internalType: 'address', type: 'address' },
          { name: 'action', internalType: 'uint8', type: 'uint8' },
          { name: 'orderId', internalType: 'uint256', type: 'uint256' },
          { name: 'nonce', internalType: 'uint256', type: 'uint256' },
          { name: 'deadline', internalType: 'uint256', type: 'uint256' },
          { name: 'paramsHash', internalType: 'bytes32', type: 'bytes32' },
          { name: 'signature', internalType: 'bytes', type: 'bytes' },
        ],
      },
      {
        name: 'fee',
        internalType: 'struct GateTypes.FeeAttestation',
        type: 'tuple',
        components: [
          { name: 'account', internalType: 'address', type: 'address' },
          { name: 'action', internalType: 'uint8', type: 'uint8' },
          { name: 'nonce', internalType: 'uint256', type: 'uint256' },
          { name: 'deadline', internalType: 'uint256', type: 'uint256' },
          { name: 'paramsHash', internalType: 'bytes32', type: 'bytes32' },
          { name: 'makerFeeBps', internalType: 'uint16', type: 'uint16' },
          { name: 'takerFeeBps', internalType: 'uint16', type: 'uint16' },
          { name: 'feeCollector', internalType: 'address', type: 'address' },
          { name: 'feeToken', internalType: 'address', type: 'address' },
          { name: 'signature', internalType: 'bytes', type: 'bytes' },
        ],
      },
    ],
    name: 'redeemPrimary',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'role', internalType: 'bytes32', type: 'bytes32' },
      { name: 'callerConfirmation', internalType: 'address', type: 'address' },
    ],
    name: 'renounceRole',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'role', internalType: 'bytes32', type: 'bytes32' },
      { name: 'account', internalType: 'address', type: 'address' },
    ],
    name: 'revokeRole',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'collector', internalType: 'address', type: 'address' },
      { name: 'allowed', internalType: 'bool', type: 'bool' },
    ],
    name: 'setAllowedCollector',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      {
        name: 'action',
        internalType: 'enum PrimaryTypes.Action',
        type: 'uint8',
      },
      { name: 'required', internalType: 'bool', type: 'bool' },
    ],
    name: 'setComplianceRequired',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'token', internalType: 'address', type: 'address' },
      { name: 'wholeUnits', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'setSettlementCap',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'venueCalldata', internalType: 'bytes', type: 'bytes' },
      {
        name: 'intent',
        internalType: 'struct PrimaryTypes.SettlementIntent',
        type: 'tuple',
        components: [
          { name: 'buyer', internalType: 'address', type: 'address' },
          { name: 'assetToken', internalType: 'address', type: 'address' },
          { name: 'accountingMode', internalType: 'uint8', type: 'uint8' },
          { name: 'minAssetOut', internalType: 'uint256', type: 'uint256' },
          { name: 'settlementToken', internalType: 'address', type: 'address' },
          { name: 'venueQuoteIn', internalType: 'uint256', type: 'uint256' },
          { name: 'buyerFee', internalType: 'uint256', type: 'uint256' },
          { name: 'maxSettlementIn', internalType: 'uint256', type: 'uint256' },
          { name: 'feeCollector', internalType: 'address', type: 'address' },
          { name: 'venue', internalType: 'address', type: 'address' },
          { name: 'selector', internalType: 'bytes4', type: 'bytes4' },
          { name: 'calldataHash', internalType: 'bytes32', type: 'bytes32' },
          {
            name: 'supplierReference',
            internalType: 'bytes32',
            type: 'bytes32',
          },
          { name: 'nonce', internalType: 'uint256', type: 'uint256' },
          { name: 'deadline', internalType: 'uint256', type: 'uint256' },
        ],
      },
      { name: 'intentSignature', internalType: 'bytes', type: 'bytes' },
      { name: 'buyerSignature', internalType: 'bytes', type: 'bytes' },
      {
        name: 'kyc',
        internalType: 'struct GateTypes.KycAttestation',
        type: 'tuple',
        components: [
          { name: 'account', internalType: 'address', type: 'address' },
          { name: 'action', internalType: 'uint8', type: 'uint8' },
          { name: 'orderId', internalType: 'uint256', type: 'uint256' },
          { name: 'nonce', internalType: 'uint256', type: 'uint256' },
          { name: 'deadline', internalType: 'uint256', type: 'uint256' },
          { name: 'paramsHash', internalType: 'bytes32', type: 'bytes32' },
          { name: 'signature', internalType: 'bytes', type: 'bytes' },
        ],
      },
      {
        name: 'fee',
        internalType: 'struct GateTypes.FeeAttestation',
        type: 'tuple',
        components: [
          { name: 'account', internalType: 'address', type: 'address' },
          { name: 'action', internalType: 'uint8', type: 'uint8' },
          { name: 'nonce', internalType: 'uint256', type: 'uint256' },
          { name: 'deadline', internalType: 'uint256', type: 'uint256' },
          { name: 'paramsHash', internalType: 'bytes32', type: 'bytes32' },
          { name: 'makerFeeBps', internalType: 'uint16', type: 'uint16' },
          { name: 'takerFeeBps', internalType: 'uint16', type: 'uint16' },
          { name: 'feeCollector', internalType: 'address', type: 'address' },
          { name: 'feeToken', internalType: 'address', type: 'address' },
          { name: 'signature', internalType: 'bytes', type: 'bytes' },
        ],
      },
    ],
    name: 'settlePrimary',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [{ name: 'interfaceId', internalType: 'bytes4', type: 'bytes4' }],
    name: 'supportsInterface',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'trustedForwarder',
    outputs: [{ name: '', internalType: 'address', type: 'address' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'unpause',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'newImplementation', internalType: 'address', type: 'address' },
      { name: 'data', internalType: 'bytes', type: 'bytes' },
    ],
    name: 'upgradeToAndCall',
    outputs: [],
    stateMutability: 'payable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'account', internalType: 'address', type: 'address' },
      { name: 'nonce', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'usedFeeNonce',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'buyer', internalType: 'address', type: 'address' },
      { name: 'nonce', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'usedIntentNonce',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'account', internalType: 'address', type: 'address' },
      { name: 'nonce', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'usedNonce',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'version',
    outputs: [{ name: '', internalType: 'string', type: 'string' }],
    stateMutability: 'pure',
  },
  {
    type: 'function',
    inputs: [{ name: 'destination', internalType: 'address', type: 'address' }],
    name: 'whitelistHandshake',
    outputs: [],
    stateMutability: 'payable',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'collector',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      { name: 'allowed', internalType: 'bool', type: 'bool', indexed: false },
    ],
    name: 'CollectorAllowed',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'action',
        internalType: 'enum PrimaryTypes.Action',
        type: 'uint8',
        indexed: true,
      },
      { name: 'required', internalType: 'bool', type: 'bool', indexed: false },
    ],
    name: 'ComplianceRequiredSet',
  },
  { type: 'event', anonymous: false, inputs: [], name: 'EIP712DomainChanged' },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'account',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      { name: 'action', internalType: 'uint8', type: 'uint8', indexed: true },
      {
        name: 'nonce',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'FeeConsumed',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'version',
        internalType: 'uint64',
        type: 'uint64',
        indexed: false,
      },
    ],
    name: 'Initialized',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'buyer',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      { name: 'action', internalType: 'uint8', type: 'uint8', indexed: true },
      {
        name: 'nonce',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'IntentConsumed',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'account',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      { name: 'action', internalType: 'uint8', type: 'uint8', indexed: true },
      {
        name: 'orderId',
        internalType: 'uint256',
        type: 'uint256',
        indexed: true,
      },
      {
        name: 'nonce',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'KycConsumed',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'account',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
    ],
    name: 'Paused',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'seller',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'assetToken',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'venue',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'assetIn',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'settlementToken',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
      {
        name: 'venueOut',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'assetRefund',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      { name: 'fee', internalType: 'uint256', type: 'uint256', indexed: false },
      {
        name: 'feeCollector',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
      {
        name: 'supplierReference',
        internalType: 'bytes32',
        type: 'bytes32',
        indexed: false,
      },
      {
        name: 'nonce',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'PrimaryRedeemed',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'buyer',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'assetToken',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'venue',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'assetDelivered',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'settlementToken',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
      {
        name: 'venueIn',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'refund',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      { name: 'fee', internalType: 'uint256', type: 'uint256', indexed: false },
      {
        name: 'feeCollector',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
      {
        name: 'supplierReference',
        internalType: 'bytes32',
        type: 'bytes32',
        indexed: false,
      },
      {
        name: 'nonce',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'PrimarySettled',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'role', internalType: 'bytes32', type: 'bytes32', indexed: true },
      {
        name: 'previousAdminRole',
        internalType: 'bytes32',
        type: 'bytes32',
        indexed: true,
      },
      {
        name: 'newAdminRole',
        internalType: 'bytes32',
        type: 'bytes32',
        indexed: true,
      },
    ],
    name: 'RoleAdminChanged',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'role', internalType: 'bytes32', type: 'bytes32', indexed: true },
      {
        name: 'account',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'sender',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
    ],
    name: 'RoleGranted',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'role', internalType: 'bytes32', type: 'bytes32', indexed: true },
      {
        name: 'account',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'sender',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
    ],
    name: 'RoleRevoked',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'token',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'wholeUnits',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'rawCap',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      {
        name: 'decimals',
        internalType: 'uint8',
        type: 'uint8',
        indexed: false,
      },
    ],
    name: 'SettlementCapSet',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'account',
        internalType: 'address',
        type: 'address',
        indexed: false,
      },
    ],
    name: 'Unpaused',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'implementation',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
    ],
    name: 'Upgraded',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'destination',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'amount',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'WhitelistHandshake',
  },
  { type: 'error', inputs: [], name: 'AccessControlBadConfirmation' },
  {
    type: 'error',
    inputs: [
      { name: 'account', internalType: 'address', type: 'address' },
      { name: 'neededRole', internalType: 'bytes32', type: 'bytes32' },
    ],
    name: 'AccessControlUnauthorizedAccount',
  },
  {
    type: 'error',
    inputs: [{ name: 'target', internalType: 'address', type: 'address' }],
    name: 'AddressEmptyCode',
  },
  { type: 'error', inputs: [], name: 'AssetApprovalNotCleared' },
  {
    type: 'error',
    inputs: [
      { name: 'requested', internalType: 'uint256', type: 'uint256' },
      { name: 'received', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'AssetPullMismatch',
  },
  { type: 'error', inputs: [], name: 'BuyerConsentBadSignature' },
  {
    type: 'error',
    inputs: [
      { name: 'attested', internalType: 'uint256', type: 'uint256' },
      { name: 'expected', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'BuyerFeeMismatch',
  },
  { type: 'error', inputs: [], name: 'CalldataHashMismatch' },
  { type: 'error', inputs: [], name: 'ECDSAInvalidSignature' },
  {
    type: 'error',
    inputs: [{ name: 'length', internalType: 'uint256', type: 'uint256' }],
    name: 'ECDSAInvalidSignatureLength',
  },
  {
    type: 'error',
    inputs: [{ name: 's', internalType: 'bytes32', type: 'bytes32' }],
    name: 'ECDSAInvalidSignatureS',
  },
  {
    type: 'error',
    inputs: [
      { name: 'implementation', internalType: 'address', type: 'address' },
    ],
    name: 'ERC1967InvalidImplementation',
  },
  { type: 'error', inputs: [], name: 'ERC1967NonPayable' },
  { type: 'error', inputs: [], name: 'EnforcedPause' },
  { type: 'error', inputs: [], name: 'ExpectedPause' },
  { type: 'error', inputs: [], name: 'FailedCall' },
  { type: 'error', inputs: [], name: 'FeeAccountMismatch' },
  { type: 'error', inputs: [], name: 'FeeActionMismatch' },
  { type: 'error', inputs: [], name: 'FeeBadSigner' },
  { type: 'error', inputs: [], name: 'FeeCollectorMismatch' },
  {
    type: 'error',
    inputs: [{ name: 'collector', internalType: 'address', type: 'address' }],
    name: 'FeeCollectorNotAllowed',
  },
  { type: 'error', inputs: [], name: 'FeeExpired' },
  { type: 'error', inputs: [], name: 'FeeNonceUsed' },
  {
    type: 'error',
    inputs: [{ name: 'feeToken', internalType: 'address', type: 'address' }],
    name: 'FeeTokenNotALeg',
  },
  { type: 'error', inputs: [], name: 'FeeTtlTooLong' },
  {
    type: 'error',
    inputs: [
      { name: 'destination', internalType: 'address', type: 'address' },
      { name: 'amount', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'HandshakeTransferFailed',
  },
  {
    type: 'error',
    inputs: [
      { name: 'delivered', internalType: 'uint256', type: 'uint256' },
      { name: 'minAssetOut', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'InsufficientAssetDelivered',
  },
  {
    type: 'error',
    inputs: [
      { name: 'net', internalType: 'uint256', type: 'uint256' },
      { name: 'minSettlementOut', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'InsufficientSettlementOut',
  },
  { type: 'error', inputs: [], name: 'IntentBadSigner' },
  { type: 'error', inputs: [], name: 'IntentBuyerMismatch' },
  { type: 'error', inputs: [], name: 'IntentExpired' },
  { type: 'error', inputs: [], name: 'IntentNonceUsed' },
  { type: 'error', inputs: [], name: 'IntentSellerMismatch' },
  { type: 'error', inputs: [], name: 'IntentTtlTooLong' },
  { type: 'error', inputs: [], name: 'InvalidFee' },
  { type: 'error', inputs: [], name: 'InvalidInitialization' },
  { type: 'error', inputs: [], name: 'KycAccountMismatch' },
  { type: 'error', inputs: [], name: 'KycActionMismatch' },
  { type: 'error', inputs: [], name: 'KycBadSigner' },
  { type: 'error', inputs: [], name: 'KycExpired' },
  { type: 'error', inputs: [], name: 'KycNonceUsed' },
  { type: 'error', inputs: [], name: 'KycOrderMismatch' },
  { type: 'error', inputs: [], name: 'KycTtlTooLong' },
  { type: 'error', inputs: [], name: 'MakerFeeNotSupported' },
  { type: 'error', inputs: [], name: 'MaxSettlementTooLow' },
  { type: 'error', inputs: [], name: 'MinSettlementTooHigh' },
  { type: 'error', inputs: [], name: 'NotInitializing' },
  { type: 'error', inputs: [], name: 'ParamsHashMismatch' },
  {
    type: 'error',
    inputs: [
      { name: 'token', internalType: 'address', type: 'address' },
      { name: 'amount', internalType: 'uint256', type: 'uint256' },
      { name: 'cap', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'PerTxCapExceeded',
  },
  { type: 'error', inputs: [], name: 'ReentrancyGuardReentrantCall' },
  { type: 'error', inputs: [], name: 'RouterBalanceChanged' },
  {
    type: 'error',
    inputs: [{ name: 'token', internalType: 'address', type: 'address' }],
    name: 'SafeERC20FailedOperation',
  },
  { type: 'error', inputs: [], name: 'SameToken' },
  { type: 'error', inputs: [], name: 'SelectorMismatch' },
  { type: 'error', inputs: [], name: 'SellerConsentBadSignature' },
  { type: 'error', inputs: [], name: 'SellerFeeExceedsProceeds' },
  {
    type: 'error',
    inputs: [
      { name: 'attested', internalType: 'uint256', type: 'uint256' },
      { name: 'expected', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'SellerFeeMismatch',
  },
  {
    type: 'error',
    inputs: [
      { name: 'requested', internalType: 'uint256', type: 'uint256' },
      { name: 'received', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'SettlementPullMismatch',
  },
  { type: 'error', inputs: [], name: 'ShareTransferFailed' },
  {
    type: 'error',
    inputs: [
      { name: 'token', internalType: 'address', type: 'address' },
      { name: 'decimals', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'TokenDecimalsImplausible',
  },
  {
    type: 'error',
    inputs: [{ name: 'token', internalType: 'address', type: 'address' }],
    name: 'TokenDecimalsUnavailable',
  },
  { type: 'error', inputs: [], name: 'UUPSUnauthorizedCallContext' },
  {
    type: 'error',
    inputs: [{ name: 'slot', internalType: 'bytes32', type: 'bytes32' }],
    name: 'UUPSUnsupportedProxiableUUID',
  },
  {
    type: 'error',
    inputs: [{ name: 'mode', internalType: 'uint8', type: 'uint8' }],
    name: 'UnsupportedAccountingMode',
  },
  { type: 'error', inputs: [], name: 'VenueCallFailed' },
  { type: 'error', inputs: [], name: 'VenueIsASettledToken' },
  { type: 'error', inputs: [], name: 'ZeroAddress' },
  { type: 'error', inputs: [], name: 'ZeroAmount' },
  { type: 'error', inputs: [], name: 'ZeroRedemptionQuote' },
  { type: 'error', inputs: [], name: 'ZeroVenueQuote' },
] as const

/**
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const asseteraPrimarySalesAddress = {
  1: '0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc',
  137: '0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc',
  80002: '0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc',
  11155111: '0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc',
} as const

/**
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const asseteraPrimarySalesConfig = {
  address: asseteraPrimarySalesAddress,
  abi: asseteraPrimarySalesAbi,
} as const

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// ERC2771Forwarder
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

export const erc2771ForwarderAbi = [
  {
    type: 'constructor',
    inputs: [{ name: 'name', internalType: 'string', type: 'string' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [],
    name: 'eip712Domain',
    outputs: [
      { name: 'fields', internalType: 'bytes1', type: 'bytes1' },
      { name: 'name', internalType: 'string', type: 'string' },
      { name: 'version', internalType: 'string', type: 'string' },
      { name: 'chainId', internalType: 'uint256', type: 'uint256' },
      { name: 'verifyingContract', internalType: 'address', type: 'address' },
      { name: 'salt', internalType: 'bytes32', type: 'bytes32' },
      { name: 'extensions', internalType: 'uint256[]', type: 'uint256[]' },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      {
        name: 'request',
        internalType: 'struct ERC2771Forwarder.ForwardRequestData',
        type: 'tuple',
        components: [
          { name: 'from', internalType: 'address', type: 'address' },
          { name: 'to', internalType: 'address', type: 'address' },
          { name: 'value', internalType: 'uint256', type: 'uint256' },
          { name: 'gas', internalType: 'uint256', type: 'uint256' },
          { name: 'deadline', internalType: 'uint48', type: 'uint48' },
          { name: 'data', internalType: 'bytes', type: 'bytes' },
          { name: 'signature', internalType: 'bytes', type: 'bytes' },
        ],
      },
    ],
    name: 'execute',
    outputs: [],
    stateMutability: 'payable',
  },
  {
    type: 'function',
    inputs: [
      {
        name: 'requests',
        internalType: 'struct ERC2771Forwarder.ForwardRequestData[]',
        type: 'tuple[]',
        components: [
          { name: 'from', internalType: 'address', type: 'address' },
          { name: 'to', internalType: 'address', type: 'address' },
          { name: 'value', internalType: 'uint256', type: 'uint256' },
          { name: 'gas', internalType: 'uint256', type: 'uint256' },
          { name: 'deadline', internalType: 'uint48', type: 'uint48' },
          { name: 'data', internalType: 'bytes', type: 'bytes' },
          { name: 'signature', internalType: 'bytes', type: 'bytes' },
        ],
      },
      {
        name: 'refundReceiver',
        internalType: 'address payable',
        type: 'address',
      },
    ],
    name: 'executeBatch',
    outputs: [],
    stateMutability: 'payable',
  },
  {
    type: 'function',
    inputs: [{ name: 'owner', internalType: 'address', type: 'address' }],
    name: 'nonces',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      {
        name: 'request',
        internalType: 'struct ERC2771Forwarder.ForwardRequestData',
        type: 'tuple',
        components: [
          { name: 'from', internalType: 'address', type: 'address' },
          { name: 'to', internalType: 'address', type: 'address' },
          { name: 'value', internalType: 'uint256', type: 'uint256' },
          { name: 'gas', internalType: 'uint256', type: 'uint256' },
          { name: 'deadline', internalType: 'uint48', type: 'uint48' },
          { name: 'data', internalType: 'bytes', type: 'bytes' },
          { name: 'signature', internalType: 'bytes', type: 'bytes' },
        ],
      },
    ],
    name: 'verify',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'view',
  },
  { type: 'event', anonymous: false, inputs: [], name: 'EIP712DomainChanged' },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'signer',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'nonce',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
      { name: 'success', internalType: 'bool', type: 'bool', indexed: false },
    ],
    name: 'ExecutedForwardRequest',
  },
  {
    type: 'error',
    inputs: [{ name: 'deadline', internalType: 'uint48', type: 'uint48' }],
    name: 'ERC2771ForwarderExpiredRequest',
  },
  {
    type: 'error',
    inputs: [
      { name: 'signer', internalType: 'address', type: 'address' },
      { name: 'from', internalType: 'address', type: 'address' },
    ],
    name: 'ERC2771ForwarderInvalidSigner',
  },
  {
    type: 'error',
    inputs: [
      { name: 'requestedValue', internalType: 'uint256', type: 'uint256' },
      { name: 'msgValue', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'ERC2771ForwarderMismatchedValue',
  },
  {
    type: 'error',
    inputs: [
      { name: 'target', internalType: 'address', type: 'address' },
      { name: 'forwarder', internalType: 'address', type: 'address' },
    ],
    name: 'ERC2771UntrustfulTarget',
  },
  { type: 'error', inputs: [], name: 'FailedCall' },
  {
    type: 'error',
    inputs: [
      { name: 'balance', internalType: 'uint256', type: 'uint256' },
      { name: 'needed', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'InsufficientBalance',
  },
  {
    type: 'error',
    inputs: [
      { name: 'account', internalType: 'address', type: 'address' },
      { name: 'currentNonce', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'InvalidAccountNonce',
  },
  { type: 'error', inputs: [], name: 'InvalidShortString' },
  {
    type: 'error',
    inputs: [{ name: 'str', internalType: 'string', type: 'string' }],
    name: 'StringTooLong',
  },
] as const

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// FaucetToken
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

export const faucetTokenAbi = [
  {
    type: 'constructor',
    inputs: [
      { name: 'name_', internalType: 'string', type: 'string' },
      { name: 'symbol_', internalType: 'string', type: 'string' },
      { name: 'decimals_', internalType: 'uint8', type: 'uint8' },
    ],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [],
    name: 'DOMAIN_SEPARATOR',
    outputs: [{ name: '', internalType: 'bytes32', type: 'bytes32' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'owner', internalType: 'address', type: 'address' },
      { name: 'spender', internalType: 'address', type: 'address' },
    ],
    name: 'allowance',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'spender', internalType: 'address', type: 'address' },
      { name: 'value', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'approve',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [{ name: 'account', internalType: 'address', type: 'address' }],
    name: 'balanceOf',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'decimals',
    outputs: [{ name: '', internalType: 'uint8', type: 'uint8' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [{ name: 'amount', internalType: 'uint256', type: 'uint256' }],
    name: 'drip',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [],
    name: 'eip712Domain',
    outputs: [
      { name: 'fields', internalType: 'bytes1', type: 'bytes1' },
      { name: 'name', internalType: 'string', type: 'string' },
      { name: 'version', internalType: 'string', type: 'string' },
      { name: 'chainId', internalType: 'uint256', type: 'uint256' },
      { name: 'verifyingContract', internalType: 'address', type: 'address' },
      { name: 'salt', internalType: 'bytes32', type: 'bytes32' },
      { name: 'extensions', internalType: 'uint256[]', type: 'uint256[]' },
    ],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'to', internalType: 'address', type: 'address' },
      { name: 'amount', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'mint',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [],
    name: 'name',
    outputs: [{ name: '', internalType: 'string', type: 'string' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [{ name: 'owner', internalType: 'address', type: 'address' }],
    name: 'nonces',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'owner', internalType: 'address', type: 'address' },
      { name: 'spender', internalType: 'address', type: 'address' },
      { name: 'value', internalType: 'uint256', type: 'uint256' },
      { name: 'deadline', internalType: 'uint256', type: 'uint256' },
      { name: 'v', internalType: 'uint8', type: 'uint8' },
      { name: 'r', internalType: 'bytes32', type: 'bytes32' },
      { name: 's', internalType: 'bytes32', type: 'bytes32' },
    ],
    name: 'permit',
    outputs: [],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [],
    name: 'symbol',
    outputs: [{ name: '', internalType: 'string', type: 'string' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [],
    name: 'totalSupply',
    outputs: [{ name: '', internalType: 'uint256', type: 'uint256' }],
    stateMutability: 'view',
  },
  {
    type: 'function',
    inputs: [
      { name: 'to', internalType: 'address', type: 'address' },
      { name: 'value', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'transfer',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'function',
    inputs: [
      { name: 'from', internalType: 'address', type: 'address' },
      { name: 'to', internalType: 'address', type: 'address' },
      { name: 'value', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'transferFrom',
    outputs: [{ name: '', internalType: 'bool', type: 'bool' }],
    stateMutability: 'nonpayable',
  },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      {
        name: 'owner',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'spender',
        internalType: 'address',
        type: 'address',
        indexed: true,
      },
      {
        name: 'value',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'Approval',
  },
  { type: 'event', anonymous: false, inputs: [], name: 'EIP712DomainChanged' },
  {
    type: 'event',
    anonymous: false,
    inputs: [
      { name: 'from', internalType: 'address', type: 'address', indexed: true },
      { name: 'to', internalType: 'address', type: 'address', indexed: true },
      {
        name: 'value',
        internalType: 'uint256',
        type: 'uint256',
        indexed: false,
      },
    ],
    name: 'Transfer',
  },
  { type: 'error', inputs: [], name: 'ECDSAInvalidSignature' },
  {
    type: 'error',
    inputs: [{ name: 'length', internalType: 'uint256', type: 'uint256' }],
    name: 'ECDSAInvalidSignatureLength',
  },
  {
    type: 'error',
    inputs: [{ name: 's', internalType: 'bytes32', type: 'bytes32' }],
    name: 'ECDSAInvalidSignatureS',
  },
  {
    type: 'error',
    inputs: [
      { name: 'spender', internalType: 'address', type: 'address' },
      { name: 'allowance', internalType: 'uint256', type: 'uint256' },
      { name: 'needed', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'ERC20InsufficientAllowance',
  },
  {
    type: 'error',
    inputs: [
      { name: 'sender', internalType: 'address', type: 'address' },
      { name: 'balance', internalType: 'uint256', type: 'uint256' },
      { name: 'needed', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'ERC20InsufficientBalance',
  },
  {
    type: 'error',
    inputs: [{ name: 'approver', internalType: 'address', type: 'address' }],
    name: 'ERC20InvalidApprover',
  },
  {
    type: 'error',
    inputs: [{ name: 'receiver', internalType: 'address', type: 'address' }],
    name: 'ERC20InvalidReceiver',
  },
  {
    type: 'error',
    inputs: [{ name: 'sender', internalType: 'address', type: 'address' }],
    name: 'ERC20InvalidSender',
  },
  {
    type: 'error',
    inputs: [{ name: 'spender', internalType: 'address', type: 'address' }],
    name: 'ERC20InvalidSpender',
  },
  {
    type: 'error',
    inputs: [{ name: 'deadline', internalType: 'uint256', type: 'uint256' }],
    name: 'ERC2612ExpiredSignature',
  },
  {
    type: 'error',
    inputs: [
      { name: 'signer', internalType: 'address', type: 'address' },
      { name: 'owner', internalType: 'address', type: 'address' },
    ],
    name: 'ERC2612InvalidSigner',
  },
  {
    type: 'error',
    inputs: [
      { name: 'account', internalType: 'address', type: 'address' },
      { name: 'currentNonce', internalType: 'uint256', type: 'uint256' },
    ],
    name: 'InvalidAccountNonce',
  },
  { type: 'error', inputs: [], name: 'InvalidShortString' },
  {
    type: 'error',
    inputs: [{ name: 'str', internalType: 'string', type: 'string' }],
    name: 'StringTooLong',
  },
] as const

//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// React
//////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcs = /*#__PURE__*/ createUseReadContract({
  abi: asseteraEcsAbi,
  address: asseteraEcsAddress,
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"DEFAULT_ADMIN_ROLE"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsDefaultAdminRole =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'DEFAULT_ADMIN_ROLE',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"FEE_OPERATOR_ROLE"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsFeeOperatorRole =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'FEE_OPERATOR_ROLE',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"FEE_TYPEHASH"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsFeeTypehash =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'FEE_TYPEHASH',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"KYC_OPERATOR_ROLE"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsKycOperatorRole =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'KYC_OPERATOR_ROLE',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"KYC_TYPEHASH"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsKycTypehash =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'KYC_TYPEHASH',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"MAX_FEE_BPS"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsMaxFeeBps = /*#__PURE__*/ createUseReadContract({
  abi: asseteraEcsAbi,
  address: asseteraEcsAddress,
  functionName: 'MAX_FEE_BPS',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"MAX_FEE_TTL"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsMaxFeeTtl = /*#__PURE__*/ createUseReadContract({
  abi: asseteraEcsAbi,
  address: asseteraEcsAddress,
  functionName: 'MAX_FEE_TTL',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"MAX_KYC_TTL"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsMaxKycTtl = /*#__PURE__*/ createUseReadContract({
  abi: asseteraEcsAbi,
  address: asseteraEcsAddress,
  functionName: 'MAX_KYC_TTL',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"UPGRADE_INTERFACE_VERSION"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsUpgradeInterfaceVersion =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'UPGRADE_INTERFACE_VERSION',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"allowedCollectors"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsAllowedCollectors =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'allowedCollectors',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"complianceRequired"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsComplianceRequired =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'complianceRequired',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"eip712Domain"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsEip712Domain =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'eip712Domain',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"getOffer"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsGetOffer = /*#__PURE__*/ createUseReadContract({
  abi: asseteraEcsAbi,
  address: asseteraEcsAddress,
  functionName: 'getOffer',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"getOrder"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsGetOrder = /*#__PURE__*/ createUseReadContract({
  abi: asseteraEcsAbi,
  address: asseteraEcsAddress,
  functionName: 'getOrder',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"getRoleAdmin"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsGetRoleAdmin =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'getRoleAdmin',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"hasRole"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsHasRole = /*#__PURE__*/ createUseReadContract({
  abi: asseteraEcsAbi,
  address: asseteraEcsAddress,
  functionName: 'hasRole',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"isTrustedForwarder"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsIsTrustedForwarder =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'isTrustedForwarder',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"paused"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsPaused = /*#__PURE__*/ createUseReadContract({
  abi: asseteraEcsAbi,
  address: asseteraEcsAddress,
  functionName: 'paused',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"proxiableUUID"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsProxiableUuid =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'proxiableUUID',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"supportsInterface"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsSupportsInterface =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'supportsInterface',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"totalOffers"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsTotalOffers =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'totalOffers',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"totalOrders"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsTotalOrders =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'totalOrders',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"trustedForwarder"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsTrustedForwarder =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'trustedForwarder',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"usedFeeNonce"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsUsedFeeNonce =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'usedFeeNonce',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"usedNonce"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsUsedNonce = /*#__PURE__*/ createUseReadContract({
  abi: asseteraEcsAbi,
  address: asseteraEcsAddress,
  functionName: 'usedNonce',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"version"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useReadAsseteraEcsVersion = /*#__PURE__*/ createUseReadContract({
  abi: asseteraEcsAbi,
  address: asseteraEcsAddress,
  functionName: 'version',
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraEcsAbi}__
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWriteAsseteraEcs = /*#__PURE__*/ createUseWriteContract({
  abi: asseteraEcsAbi,
  address: asseteraEcsAddress,
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"acceptOffer"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWriteAsseteraEcsAcceptOffer =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'acceptOffer',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"cancelOffer"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWriteAsseteraEcsCancelOffer =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'cancelOffer',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"cancelOfferForUser"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWriteAsseteraEcsCancelOfferForUser =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'cancelOfferForUser',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"cancelOrder"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWriteAsseteraEcsCancelOrder =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'cancelOrder',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"cancelOrderForUser"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWriteAsseteraEcsCancelOrderForUser =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'cancelOrderForUser',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"fillOrder"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWriteAsseteraEcsFillOrder =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'fillOrder',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"grantRole"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWriteAsseteraEcsGrantRole =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'grantRole',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"initialize"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWriteAsseteraEcsInitialize =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'initialize',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"makeOffer"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWriteAsseteraEcsMakeOffer =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'makeOffer',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"pause"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWriteAsseteraEcsPause = /*#__PURE__*/ createUseWriteContract({
  abi: asseteraEcsAbi,
  address: asseteraEcsAddress,
  functionName: 'pause',
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"permitAndCall"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWriteAsseteraEcsPermitAndCall =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'permitAndCall',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"placeOrder"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWriteAsseteraEcsPlaceOrder =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'placeOrder',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"placeOrderWithPermit"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWriteAsseteraEcsPlaceOrderWithPermit =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'placeOrderWithPermit',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"renounceRole"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWriteAsseteraEcsRenounceRole =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'renounceRole',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"replaceOffer"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWriteAsseteraEcsReplaceOffer =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'replaceOffer',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"revokeRole"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWriteAsseteraEcsRevokeRole =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'revokeRole',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"setAllowedCollector"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWriteAsseteraEcsSetAllowedCollector =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'setAllowedCollector',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"setComplianceRequired"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWriteAsseteraEcsSetComplianceRequired =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'setComplianceRequired',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"sweepExpired"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWriteAsseteraEcsSweepExpired =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'sweepExpired',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"sweepExpiredOffers"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWriteAsseteraEcsSweepExpiredOffers =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'sweepExpiredOffers',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"unpause"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWriteAsseteraEcsUnpause = /*#__PURE__*/ createUseWriteContract({
  abi: asseteraEcsAbi,
  address: asseteraEcsAddress,
  functionName: 'unpause',
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"upgradeToAndCall"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWriteAsseteraEcsUpgradeToAndCall =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'upgradeToAndCall',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraEcsAbi}__
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useSimulateAsseteraEcs = /*#__PURE__*/ createUseSimulateContract({
  abi: asseteraEcsAbi,
  address: asseteraEcsAddress,
})

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"acceptOffer"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useSimulateAsseteraEcsAcceptOffer =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'acceptOffer',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"cancelOffer"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useSimulateAsseteraEcsCancelOffer =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'cancelOffer',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"cancelOfferForUser"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useSimulateAsseteraEcsCancelOfferForUser =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'cancelOfferForUser',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"cancelOrder"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useSimulateAsseteraEcsCancelOrder =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'cancelOrder',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"cancelOrderForUser"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useSimulateAsseteraEcsCancelOrderForUser =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'cancelOrderForUser',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"fillOrder"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useSimulateAsseteraEcsFillOrder =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'fillOrder',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"grantRole"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useSimulateAsseteraEcsGrantRole =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'grantRole',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"initialize"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useSimulateAsseteraEcsInitialize =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'initialize',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"makeOffer"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useSimulateAsseteraEcsMakeOffer =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'makeOffer',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"pause"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useSimulateAsseteraEcsPause =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'pause',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"permitAndCall"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useSimulateAsseteraEcsPermitAndCall =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'permitAndCall',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"placeOrder"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useSimulateAsseteraEcsPlaceOrder =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'placeOrder',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"placeOrderWithPermit"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useSimulateAsseteraEcsPlaceOrderWithPermit =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'placeOrderWithPermit',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"renounceRole"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useSimulateAsseteraEcsRenounceRole =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'renounceRole',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"replaceOffer"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useSimulateAsseteraEcsReplaceOffer =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'replaceOffer',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"revokeRole"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useSimulateAsseteraEcsRevokeRole =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'revokeRole',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"setAllowedCollector"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useSimulateAsseteraEcsSetAllowedCollector =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'setAllowedCollector',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"setComplianceRequired"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useSimulateAsseteraEcsSetComplianceRequired =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'setComplianceRequired',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"sweepExpired"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useSimulateAsseteraEcsSweepExpired =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'sweepExpired',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"sweepExpiredOffers"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useSimulateAsseteraEcsSweepExpiredOffers =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'sweepExpiredOffers',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"unpause"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useSimulateAsseteraEcsUnpause =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'unpause',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraEcsAbi}__ and `functionName` set to `"upgradeToAndCall"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useSimulateAsseteraEcsUpgradeToAndCall =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    functionName: 'upgradeToAndCall',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"CollectorAllowed"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsCollectorAllowedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'CollectorAllowed',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"ComplianceRequiredSet"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsComplianceRequiredSetEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'ComplianceRequiredSet',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"EIP712DomainChanged"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsEip712DomainChangedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'EIP712DomainChanged',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"FeeConsumed"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsFeeConsumedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'FeeConsumed',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"Initialized"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsInitializedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'Initialized',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"KycConsumed"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsKycConsumedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'KycConsumed',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"OfferAccepted"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsOfferAcceptedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'OfferAccepted',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"OfferCancelled"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsOfferCancelledEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'OfferCancelled',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"OfferExpired"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsOfferExpiredEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'OfferExpired',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"OfferForceCancelled"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsOfferForceCancelledEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'OfferForceCancelled',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"OfferMade"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsOfferMadeEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'OfferMade',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"OfferReplaced"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsOfferReplacedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'OfferReplaced',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"OfferSettled"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsOfferSettledEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'OfferSettled',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"OrderCancelled"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsOrderCancelledEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'OrderCancelled',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"OrderClosedByOffer"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsOrderClosedByOfferEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'OrderClosedByOffer',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"OrderEscrowDrawn"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsOrderEscrowDrawnEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'OrderEscrowDrawn',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"OrderExpired"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsOrderExpiredEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'OrderExpired',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"OrderFilled"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsOrderFilledEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'OrderFilled',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"OrderForceCancelled"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsOrderForceCancelledEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'OrderForceCancelled',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"OrderPartiallyFilled"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsOrderPartiallyFilledEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'OrderPartiallyFilled',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"OrderPlaced"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsOrderPlacedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'OrderPlaced',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"Paused"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsPausedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'Paused',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"RoleAdminChanged"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsRoleAdminChangedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'RoleAdminChanged',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"RoleGranted"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsRoleGrantedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'RoleGranted',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"RoleRevoked"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsRoleRevokedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'RoleRevoked',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"Unpaused"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsUnpausedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'Unpaused',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraEcsAbi}__ and `eventName` set to `"Upgraded"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xf045d3FE81C14d8c13DbaB0b03a4Ea1505e499ad)
 */
export const useWatchAsseteraEcsUpgradedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraEcsAbi,
    address: asseteraEcsAddress,
    eventName: 'Upgraded',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__
 */
export const useReadAsseteraIssuanceVenue = /*#__PURE__*/ createUseReadContract(
  { abi: asseteraIssuanceVenueAbi },
)

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"ASSET_DECIMALS"`
 */
export const useReadAsseteraIssuanceVenueAssetDecimals =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'ASSET_DECIMALS',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"ASSET_TOKEN"`
 */
export const useReadAsseteraIssuanceVenueAssetToken =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'ASSET_TOKEN',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"ASSET_UNIT"`
 */
export const useReadAsseteraIssuanceVenueAssetUnit =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'ASSET_UNIT',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"DEFAULT_ADMIN_ROLE"`
 */
export const useReadAsseteraIssuanceVenueDefaultAdminRole =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'DEFAULT_ADMIN_ROLE',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"MAX_TOKEN_DECIMALS"`
 */
export const useReadAsseteraIssuanceVenueMaxTokenDecimals =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'MAX_TOKEN_DECIMALS',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"MAX_UNIT_PRICE"`
 */
export const useReadAsseteraIssuanceVenueMaxUnitPrice =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'MAX_UNIT_PRICE',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"MIN_UNIT_PRICE"`
 */
export const useReadAsseteraIssuanceVenueMinUnitPrice =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'MIN_UNIT_PRICE',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"PAUSER_ROLE"`
 */
export const useReadAsseteraIssuanceVenuePauserRole =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'PAUSER_ROLE',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"RATE_SETTER_ROLE"`
 */
export const useReadAsseteraIssuanceVenueRateSetterRole =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'RATE_SETTER_ROLE',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"ROUTER"`
 */
export const useReadAsseteraIssuanceVenueRouter =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'ROUTER',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"SETTLEMENT_DECIMALS"`
 */
export const useReadAsseteraIssuanceVenueSettlementDecimals =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'SETTLEMENT_DECIMALS',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"SETTLEMENT_TOKEN"`
 */
export const useReadAsseteraIssuanceVenueSettlementToken =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'SETTLEMENT_TOKEN',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"TREASURY_ROLE"`
 */
export const useReadAsseteraIssuanceVenueTreasuryRole =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'TREASURY_ROLE',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"getRoleAdmin"`
 */
export const useReadAsseteraIssuanceVenueGetRoleAdmin =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'getRoleAdmin',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"hasRole"`
 */
export const useReadAsseteraIssuanceVenueHasRole =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'hasRole',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"maxSettlementPerPurchase"`
 */
export const useReadAsseteraIssuanceVenueMaxSettlementPerPurchase =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'maxSettlementPerPurchase',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"maxSettlementPerPurchaseWholeUnits"`
 */
export const useReadAsseteraIssuanceVenueMaxSettlementPerPurchaseWholeUnits =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'maxSettlementPerPurchaseWholeUnits',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"paused"`
 */
export const useReadAsseteraIssuanceVenuePaused =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'paused',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"quoteAssetOut"`
 */
export const useReadAsseteraIssuanceVenueQuoteAssetOut =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'quoteAssetOut',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"quoteSettlementIn"`
 */
export const useReadAsseteraIssuanceVenueQuoteSettlementIn =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'quoteSettlementIn',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"supportsInterface"`
 */
export const useReadAsseteraIssuanceVenueSupportsInterface =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'supportsInterface',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"unitPrice"`
 */
export const useReadAsseteraIssuanceVenueUnitPrice =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'unitPrice',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__
 */
export const useWriteAsseteraIssuanceVenue =
  /*#__PURE__*/ createUseWriteContract({ abi: asseteraIssuanceVenueAbi })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"grantRole"`
 */
export const useWriteAsseteraIssuanceVenueGrantRole =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'grantRole',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"pause"`
 */
export const useWriteAsseteraIssuanceVenuePause =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'pause',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"purchase"`
 */
export const useWriteAsseteraIssuanceVenuePurchase =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'purchase',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"renounceRole"`
 */
export const useWriteAsseteraIssuanceVenueRenounceRole =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'renounceRole',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"rescue"`
 */
export const useWriteAsseteraIssuanceVenueRescue =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'rescue',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"revokeRole"`
 */
export const useWriteAsseteraIssuanceVenueRevokeRole =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'revokeRole',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"setMaxSettlementPerPurchase"`
 */
export const useWriteAsseteraIssuanceVenueSetMaxSettlementPerPurchase =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'setMaxSettlementPerPurchase',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"setUnitPrice"`
 */
export const useWriteAsseteraIssuanceVenueSetUnitPrice =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'setUnitPrice',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"unpause"`
 */
export const useWriteAsseteraIssuanceVenueUnpause =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'unpause',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"withdraw"`
 */
export const useWriteAsseteraIssuanceVenueWithdraw =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'withdraw',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__
 */
export const useSimulateAsseteraIssuanceVenue =
  /*#__PURE__*/ createUseSimulateContract({ abi: asseteraIssuanceVenueAbi })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"grantRole"`
 */
export const useSimulateAsseteraIssuanceVenueGrantRole =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'grantRole',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"pause"`
 */
export const useSimulateAsseteraIssuanceVenuePause =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'pause',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"purchase"`
 */
export const useSimulateAsseteraIssuanceVenuePurchase =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'purchase',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"renounceRole"`
 */
export const useSimulateAsseteraIssuanceVenueRenounceRole =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'renounceRole',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"rescue"`
 */
export const useSimulateAsseteraIssuanceVenueRescue =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'rescue',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"revokeRole"`
 */
export const useSimulateAsseteraIssuanceVenueRevokeRole =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'revokeRole',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"setMaxSettlementPerPurchase"`
 */
export const useSimulateAsseteraIssuanceVenueSetMaxSettlementPerPurchase =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'setMaxSettlementPerPurchase',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"setUnitPrice"`
 */
export const useSimulateAsseteraIssuanceVenueSetUnitPrice =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'setUnitPrice',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"unpause"`
 */
export const useSimulateAsseteraIssuanceVenueUnpause =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'unpause',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `functionName` set to `"withdraw"`
 */
export const useSimulateAsseteraIssuanceVenueWithdraw =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraIssuanceVenueAbi,
    functionName: 'withdraw',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__
 */
export const useWatchAsseteraIssuanceVenueEvent =
  /*#__PURE__*/ createUseWatchContractEvent({ abi: asseteraIssuanceVenueAbi })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `eventName` set to `"IssuanceMinted"`
 */
export const useWatchAsseteraIssuanceVenueIssuanceMintedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraIssuanceVenueAbi,
    eventName: 'IssuanceMinted',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `eventName` set to `"Paused"`
 */
export const useWatchAsseteraIssuanceVenuePausedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraIssuanceVenueAbi,
    eventName: 'Paused',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `eventName` set to `"ProceedsWithdrawn"`
 */
export const useWatchAsseteraIssuanceVenueProceedsWithdrawnEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraIssuanceVenueAbi,
    eventName: 'ProceedsWithdrawn',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `eventName` set to `"PurchaseCapSet"`
 */
export const useWatchAsseteraIssuanceVenuePurchaseCapSetEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraIssuanceVenueAbi,
    eventName: 'PurchaseCapSet',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `eventName` set to `"RoleAdminChanged"`
 */
export const useWatchAsseteraIssuanceVenueRoleAdminChangedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraIssuanceVenueAbi,
    eventName: 'RoleAdminChanged',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `eventName` set to `"RoleGranted"`
 */
export const useWatchAsseteraIssuanceVenueRoleGrantedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraIssuanceVenueAbi,
    eventName: 'RoleGranted',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `eventName` set to `"RoleRevoked"`
 */
export const useWatchAsseteraIssuanceVenueRoleRevokedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraIssuanceVenueAbi,
    eventName: 'RoleRevoked',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `eventName` set to `"TokensRescued"`
 */
export const useWatchAsseteraIssuanceVenueTokensRescuedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraIssuanceVenueAbi,
    eventName: 'TokensRescued',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `eventName` set to `"UnitPriceSet"`
 */
export const useWatchAsseteraIssuanceVenueUnitPriceSetEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraIssuanceVenueAbi,
    eventName: 'UnitPriceSet',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraIssuanceVenueAbi}__ and `eventName` set to `"Unpaused"`
 */
export const useWatchAsseteraIssuanceVenueUnpausedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraIssuanceVenueAbi,
    eventName: 'Unpaused',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySales = /*#__PURE__*/ createUseReadContract({
  abi: asseteraPrimarySalesAbi,
  address: asseteraPrimarySalesAddress,
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"DEFAULT_ADMIN_ROLE"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesDefaultAdminRole =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'DEFAULT_ADMIN_ROLE',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"FEE_OPERATOR_ROLE"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesFeeOperatorRole =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'FEE_OPERATOR_ROLE',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"FEE_TYPEHASH"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesFeeTypehash =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'FEE_TYPEHASH',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"INTENT_TYPEHASH"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesIntentTypehash =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'INTENT_TYPEHASH',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"KYC_OPERATOR_ROLE"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesKycOperatorRole =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'KYC_OPERATOR_ROLE',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"KYC_TYPEHASH"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesKycTypehash =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'KYC_TYPEHASH',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"MAX_FEE_BPS"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesMaxFeeBps =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'MAX_FEE_BPS',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"MAX_FEE_TTL"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesMaxFeeTtl =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'MAX_FEE_TTL',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"MAX_INTENT_TTL"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesMaxIntentTtl =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'MAX_INTENT_TTL',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"MAX_KYC_TTL"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesMaxKycTtl =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'MAX_KYC_TTL',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"MAX_SETTLEMENT_TOKEN_DECIMALS"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesMaxSettlementTokenDecimals =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'MAX_SETTLEMENT_TOKEN_DECIMALS',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"REDEMPTION_TYPEHASH"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesRedemptionTypehash =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'REDEMPTION_TYPEHASH',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"SETTLEMENT_OPERATOR_ROLE"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesSettlementOperatorRole =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'SETTLEMENT_OPERATOR_ROLE',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"UPGRADE_INTERFACE_VERSION"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesUpgradeInterfaceVersion =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'UPGRADE_INTERFACE_VERSION',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"allowedCollectors"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesAllowedCollectors =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'allowedCollectors',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"complianceRequired"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesComplianceRequired =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'complianceRequired',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"eip712Domain"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesEip712Domain =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'eip712Domain',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"getRoleAdmin"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesGetRoleAdmin =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'getRoleAdmin',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"hasRole"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesHasRole =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'hasRole',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"isTrustedForwarder"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesIsTrustedForwarder =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'isTrustedForwarder',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"paused"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesPaused =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'paused',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"perTxCap"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesPerTxCap =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'perTxCap',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"perTxCapWholeUnits"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesPerTxCapWholeUnits =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'perTxCapWholeUnits',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"proxiableUUID"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesProxiableUuid =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'proxiableUUID',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"supportsInterface"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesSupportsInterface =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'supportsInterface',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"trustedForwarder"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesTrustedForwarder =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'trustedForwarder',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"usedFeeNonce"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesUsedFeeNonce =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'usedFeeNonce',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"usedIntentNonce"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesUsedIntentNonce =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'usedIntentNonce',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"usedNonce"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesUsedNonce =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'usedNonce',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"version"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useReadAsseteraPrimarySalesVersion =
  /*#__PURE__*/ createUseReadContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'version',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWriteAsseteraPrimarySales =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"grantRole"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWriteAsseteraPrimarySalesGrantRole =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'grantRole',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"initialize"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWriteAsseteraPrimarySalesInitialize =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'initialize',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"pause"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWriteAsseteraPrimarySalesPause =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'pause',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"permitAndCall"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWriteAsseteraPrimarySalesPermitAndCall =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'permitAndCall',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"redeemPrimary"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWriteAsseteraPrimarySalesRedeemPrimary =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'redeemPrimary',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"renounceRole"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWriteAsseteraPrimarySalesRenounceRole =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'renounceRole',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"revokeRole"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWriteAsseteraPrimarySalesRevokeRole =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'revokeRole',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"setAllowedCollector"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWriteAsseteraPrimarySalesSetAllowedCollector =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'setAllowedCollector',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"setComplianceRequired"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWriteAsseteraPrimarySalesSetComplianceRequired =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'setComplianceRequired',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"setSettlementCap"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWriteAsseteraPrimarySalesSetSettlementCap =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'setSettlementCap',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"settlePrimary"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWriteAsseteraPrimarySalesSettlePrimary =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'settlePrimary',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"unpause"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWriteAsseteraPrimarySalesUnpause =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'unpause',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"upgradeToAndCall"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWriteAsseteraPrimarySalesUpgradeToAndCall =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'upgradeToAndCall',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"whitelistHandshake"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWriteAsseteraPrimarySalesWhitelistHandshake =
  /*#__PURE__*/ createUseWriteContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'whitelistHandshake',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useSimulateAsseteraPrimarySales =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"grantRole"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useSimulateAsseteraPrimarySalesGrantRole =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'grantRole',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"initialize"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useSimulateAsseteraPrimarySalesInitialize =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'initialize',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"pause"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useSimulateAsseteraPrimarySalesPause =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'pause',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"permitAndCall"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useSimulateAsseteraPrimarySalesPermitAndCall =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'permitAndCall',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"redeemPrimary"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useSimulateAsseteraPrimarySalesRedeemPrimary =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'redeemPrimary',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"renounceRole"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useSimulateAsseteraPrimarySalesRenounceRole =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'renounceRole',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"revokeRole"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useSimulateAsseteraPrimarySalesRevokeRole =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'revokeRole',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"setAllowedCollector"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useSimulateAsseteraPrimarySalesSetAllowedCollector =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'setAllowedCollector',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"setComplianceRequired"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useSimulateAsseteraPrimarySalesSetComplianceRequired =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'setComplianceRequired',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"setSettlementCap"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useSimulateAsseteraPrimarySalesSetSettlementCap =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'setSettlementCap',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"settlePrimary"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useSimulateAsseteraPrimarySalesSettlePrimary =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'settlePrimary',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"unpause"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useSimulateAsseteraPrimarySalesUnpause =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'unpause',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"upgradeToAndCall"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useSimulateAsseteraPrimarySalesUpgradeToAndCall =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'upgradeToAndCall',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `functionName` set to `"whitelistHandshake"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useSimulateAsseteraPrimarySalesWhitelistHandshake =
  /*#__PURE__*/ createUseSimulateContract({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    functionName: 'whitelistHandshake',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWatchAsseteraPrimarySalesEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `eventName` set to `"CollectorAllowed"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWatchAsseteraPrimarySalesCollectorAllowedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    eventName: 'CollectorAllowed',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `eventName` set to `"ComplianceRequiredSet"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWatchAsseteraPrimarySalesComplianceRequiredSetEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    eventName: 'ComplianceRequiredSet',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `eventName` set to `"EIP712DomainChanged"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWatchAsseteraPrimarySalesEip712DomainChangedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    eventName: 'EIP712DomainChanged',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `eventName` set to `"FeeConsumed"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWatchAsseteraPrimarySalesFeeConsumedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    eventName: 'FeeConsumed',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `eventName` set to `"Initialized"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWatchAsseteraPrimarySalesInitializedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    eventName: 'Initialized',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `eventName` set to `"IntentConsumed"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWatchAsseteraPrimarySalesIntentConsumedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    eventName: 'IntentConsumed',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `eventName` set to `"KycConsumed"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWatchAsseteraPrimarySalesKycConsumedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    eventName: 'KycConsumed',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `eventName` set to `"Paused"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWatchAsseteraPrimarySalesPausedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    eventName: 'Paused',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `eventName` set to `"PrimaryRedeemed"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWatchAsseteraPrimarySalesPrimaryRedeemedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    eventName: 'PrimaryRedeemed',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `eventName` set to `"PrimarySettled"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWatchAsseteraPrimarySalesPrimarySettledEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    eventName: 'PrimarySettled',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `eventName` set to `"RoleAdminChanged"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWatchAsseteraPrimarySalesRoleAdminChangedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    eventName: 'RoleAdminChanged',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `eventName` set to `"RoleGranted"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWatchAsseteraPrimarySalesRoleGrantedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    eventName: 'RoleGranted',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `eventName` set to `"RoleRevoked"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWatchAsseteraPrimarySalesRoleRevokedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    eventName: 'RoleRevoked',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `eventName` set to `"SettlementCapSet"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWatchAsseteraPrimarySalesSettlementCapSetEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    eventName: 'SettlementCapSet',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `eventName` set to `"Unpaused"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWatchAsseteraPrimarySalesUnpausedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    eventName: 'Unpaused',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `eventName` set to `"Upgraded"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWatchAsseteraPrimarySalesUpgradedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    eventName: 'Upgraded',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link asseteraPrimarySalesAbi}__ and `eventName` set to `"WhitelistHandshake"`
 *
 * - [__View Contract on Ethereum Etherscan__](https://etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Polygon Scan__](https://polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Polygon Amoy Polygon Scan__](https://amoy.polygonscan.com/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 * - [__View Contract on Sepolia Etherscan__](https://sepolia.etherscan.io/address/0xF62757dd232DC7582A5d46F62aAcDb6B739223Dc)
 */
export const useWatchAsseteraPrimarySalesWhitelistHandshakeEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: asseteraPrimarySalesAbi,
    address: asseteraPrimarySalesAddress,
    eventName: 'WhitelistHandshake',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link erc2771ForwarderAbi}__
 */
export const useReadErc2771Forwarder = /*#__PURE__*/ createUseReadContract({
  abi: erc2771ForwarderAbi,
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link erc2771ForwarderAbi}__ and `functionName` set to `"eip712Domain"`
 */
export const useReadErc2771ForwarderEip712Domain =
  /*#__PURE__*/ createUseReadContract({
    abi: erc2771ForwarderAbi,
    functionName: 'eip712Domain',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link erc2771ForwarderAbi}__ and `functionName` set to `"nonces"`
 */
export const useReadErc2771ForwarderNonces =
  /*#__PURE__*/ createUseReadContract({
    abi: erc2771ForwarderAbi,
    functionName: 'nonces',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link erc2771ForwarderAbi}__ and `functionName` set to `"verify"`
 */
export const useReadErc2771ForwarderVerify =
  /*#__PURE__*/ createUseReadContract({
    abi: erc2771ForwarderAbi,
    functionName: 'verify',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link erc2771ForwarderAbi}__
 */
export const useWriteErc2771Forwarder = /*#__PURE__*/ createUseWriteContract({
  abi: erc2771ForwarderAbi,
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link erc2771ForwarderAbi}__ and `functionName` set to `"execute"`
 */
export const useWriteErc2771ForwarderExecute =
  /*#__PURE__*/ createUseWriteContract({
    abi: erc2771ForwarderAbi,
    functionName: 'execute',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link erc2771ForwarderAbi}__ and `functionName` set to `"executeBatch"`
 */
export const useWriteErc2771ForwarderExecuteBatch =
  /*#__PURE__*/ createUseWriteContract({
    abi: erc2771ForwarderAbi,
    functionName: 'executeBatch',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link erc2771ForwarderAbi}__
 */
export const useSimulateErc2771Forwarder =
  /*#__PURE__*/ createUseSimulateContract({ abi: erc2771ForwarderAbi })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link erc2771ForwarderAbi}__ and `functionName` set to `"execute"`
 */
export const useSimulateErc2771ForwarderExecute =
  /*#__PURE__*/ createUseSimulateContract({
    abi: erc2771ForwarderAbi,
    functionName: 'execute',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link erc2771ForwarderAbi}__ and `functionName` set to `"executeBatch"`
 */
export const useSimulateErc2771ForwarderExecuteBatch =
  /*#__PURE__*/ createUseSimulateContract({
    abi: erc2771ForwarderAbi,
    functionName: 'executeBatch',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link erc2771ForwarderAbi}__
 */
export const useWatchErc2771ForwarderEvent =
  /*#__PURE__*/ createUseWatchContractEvent({ abi: erc2771ForwarderAbi })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link erc2771ForwarderAbi}__ and `eventName` set to `"EIP712DomainChanged"`
 */
export const useWatchErc2771ForwarderEip712DomainChangedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: erc2771ForwarderAbi,
    eventName: 'EIP712DomainChanged',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link erc2771ForwarderAbi}__ and `eventName` set to `"ExecutedForwardRequest"`
 */
export const useWatchErc2771ForwarderExecutedForwardRequestEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: erc2771ForwarderAbi,
    eventName: 'ExecutedForwardRequest',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link faucetTokenAbi}__
 */
export const useReadFaucetToken = /*#__PURE__*/ createUseReadContract({
  abi: faucetTokenAbi,
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link faucetTokenAbi}__ and `functionName` set to `"DOMAIN_SEPARATOR"`
 */
export const useReadFaucetTokenDomainSeparator =
  /*#__PURE__*/ createUseReadContract({
    abi: faucetTokenAbi,
    functionName: 'DOMAIN_SEPARATOR',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link faucetTokenAbi}__ and `functionName` set to `"allowance"`
 */
export const useReadFaucetTokenAllowance = /*#__PURE__*/ createUseReadContract({
  abi: faucetTokenAbi,
  functionName: 'allowance',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link faucetTokenAbi}__ and `functionName` set to `"balanceOf"`
 */
export const useReadFaucetTokenBalanceOf = /*#__PURE__*/ createUseReadContract({
  abi: faucetTokenAbi,
  functionName: 'balanceOf',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link faucetTokenAbi}__ and `functionName` set to `"decimals"`
 */
export const useReadFaucetTokenDecimals = /*#__PURE__*/ createUseReadContract({
  abi: faucetTokenAbi,
  functionName: 'decimals',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link faucetTokenAbi}__ and `functionName` set to `"eip712Domain"`
 */
export const useReadFaucetTokenEip712Domain =
  /*#__PURE__*/ createUseReadContract({
    abi: faucetTokenAbi,
    functionName: 'eip712Domain',
  })

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link faucetTokenAbi}__ and `functionName` set to `"name"`
 */
export const useReadFaucetTokenName = /*#__PURE__*/ createUseReadContract({
  abi: faucetTokenAbi,
  functionName: 'name',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link faucetTokenAbi}__ and `functionName` set to `"nonces"`
 */
export const useReadFaucetTokenNonces = /*#__PURE__*/ createUseReadContract({
  abi: faucetTokenAbi,
  functionName: 'nonces',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link faucetTokenAbi}__ and `functionName` set to `"symbol"`
 */
export const useReadFaucetTokenSymbol = /*#__PURE__*/ createUseReadContract({
  abi: faucetTokenAbi,
  functionName: 'symbol',
})

/**
 * Wraps __{@link useReadContract}__ with `abi` set to __{@link faucetTokenAbi}__ and `functionName` set to `"totalSupply"`
 */
export const useReadFaucetTokenTotalSupply =
  /*#__PURE__*/ createUseReadContract({
    abi: faucetTokenAbi,
    functionName: 'totalSupply',
  })

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link faucetTokenAbi}__
 */
export const useWriteFaucetToken = /*#__PURE__*/ createUseWriteContract({
  abi: faucetTokenAbi,
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link faucetTokenAbi}__ and `functionName` set to `"approve"`
 */
export const useWriteFaucetTokenApprove = /*#__PURE__*/ createUseWriteContract({
  abi: faucetTokenAbi,
  functionName: 'approve',
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link faucetTokenAbi}__ and `functionName` set to `"drip"`
 */
export const useWriteFaucetTokenDrip = /*#__PURE__*/ createUseWriteContract({
  abi: faucetTokenAbi,
  functionName: 'drip',
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link faucetTokenAbi}__ and `functionName` set to `"mint"`
 */
export const useWriteFaucetTokenMint = /*#__PURE__*/ createUseWriteContract({
  abi: faucetTokenAbi,
  functionName: 'mint',
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link faucetTokenAbi}__ and `functionName` set to `"permit"`
 */
export const useWriteFaucetTokenPermit = /*#__PURE__*/ createUseWriteContract({
  abi: faucetTokenAbi,
  functionName: 'permit',
})

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link faucetTokenAbi}__ and `functionName` set to `"transfer"`
 */
export const useWriteFaucetTokenTransfer = /*#__PURE__*/ createUseWriteContract(
  { abi: faucetTokenAbi, functionName: 'transfer' },
)

/**
 * Wraps __{@link useWriteContract}__ with `abi` set to __{@link faucetTokenAbi}__ and `functionName` set to `"transferFrom"`
 */
export const useWriteFaucetTokenTransferFrom =
  /*#__PURE__*/ createUseWriteContract({
    abi: faucetTokenAbi,
    functionName: 'transferFrom',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link faucetTokenAbi}__
 */
export const useSimulateFaucetToken = /*#__PURE__*/ createUseSimulateContract({
  abi: faucetTokenAbi,
})

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link faucetTokenAbi}__ and `functionName` set to `"approve"`
 */
export const useSimulateFaucetTokenApprove =
  /*#__PURE__*/ createUseSimulateContract({
    abi: faucetTokenAbi,
    functionName: 'approve',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link faucetTokenAbi}__ and `functionName` set to `"drip"`
 */
export const useSimulateFaucetTokenDrip =
  /*#__PURE__*/ createUseSimulateContract({
    abi: faucetTokenAbi,
    functionName: 'drip',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link faucetTokenAbi}__ and `functionName` set to `"mint"`
 */
export const useSimulateFaucetTokenMint =
  /*#__PURE__*/ createUseSimulateContract({
    abi: faucetTokenAbi,
    functionName: 'mint',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link faucetTokenAbi}__ and `functionName` set to `"permit"`
 */
export const useSimulateFaucetTokenPermit =
  /*#__PURE__*/ createUseSimulateContract({
    abi: faucetTokenAbi,
    functionName: 'permit',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link faucetTokenAbi}__ and `functionName` set to `"transfer"`
 */
export const useSimulateFaucetTokenTransfer =
  /*#__PURE__*/ createUseSimulateContract({
    abi: faucetTokenAbi,
    functionName: 'transfer',
  })

/**
 * Wraps __{@link useSimulateContract}__ with `abi` set to __{@link faucetTokenAbi}__ and `functionName` set to `"transferFrom"`
 */
export const useSimulateFaucetTokenTransferFrom =
  /*#__PURE__*/ createUseSimulateContract({
    abi: faucetTokenAbi,
    functionName: 'transferFrom',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link faucetTokenAbi}__
 */
export const useWatchFaucetTokenEvent =
  /*#__PURE__*/ createUseWatchContractEvent({ abi: faucetTokenAbi })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link faucetTokenAbi}__ and `eventName` set to `"Approval"`
 */
export const useWatchFaucetTokenApprovalEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: faucetTokenAbi,
    eventName: 'Approval',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link faucetTokenAbi}__ and `eventName` set to `"EIP712DomainChanged"`
 */
export const useWatchFaucetTokenEip712DomainChangedEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: faucetTokenAbi,
    eventName: 'EIP712DomainChanged',
  })

/**
 * Wraps __{@link useWatchContractEvent}__ with `abi` set to __{@link faucetTokenAbi}__ and `eventName` set to `"Transfer"`
 */
export const useWatchFaucetTokenTransferEvent =
  /*#__PURE__*/ createUseWatchContractEvent({
    abi: faucetTokenAbi,
    eventName: 'Transfer',
  })
