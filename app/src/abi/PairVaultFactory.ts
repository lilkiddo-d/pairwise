export const PairVaultFactoryAbi = [
  {
    "type": "constructor",
    "inputs": [
      {
        "name": "admin",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "vaultImpl_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "longImpl_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "shortImpl_",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "shared_",
        "type": "tuple",
        "internalType": "struct PairVaultFactory.Shared",
        "components": [
          {
            "name": "usdg",
            "type": "address",
            "internalType": "contract IERC20"
          },
          {
            "name": "morpho",
            "type": "address",
            "internalType": "contract IMorpho"
          },
          {
            "name": "venue",
            "type": "address",
            "internalType": "contract ISwapVenue"
          },
          {
            "name": "oracle",
            "type": "address",
            "internalType": "contract IPriceOracle"
          },
          {
            "name": "spreadOracle",
            "type": "address",
            "internalType": "contract ISpreadOracle"
          },
          {
            "name": "clock",
            "type": "address",
            "internalType": "contract IMarketClock"
          },
          {
            "name": "engine",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "feeCollector",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "compliance",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "vaultAdmin",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "guardian",
            "type": "address",
            "internalType": "address"
          }
        ]
      },
      {
        "name": "config_",
        "type": "tuple",
        "internalType": "struct PairVault.Config",
        "components": [
          {
            "name": "maxSlippageBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "deployBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "targetLtvBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "rebalanceLtvBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "maxLtvBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "bandBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "rebalanceTriggerBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "maxTiltBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "maxNotionalUsdg",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "depositCap",
            "type": "uint128",
            "internalType": "uint128"
          }
        ]
      },
      {
        "name": "mgmtBps",
        "type": "uint16",
        "internalType": "uint16"
      },
      {
        "name": "perfBps",
        "type": "uint16",
        "internalType": "uint16"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "DEFAULT_ADMIN_ROLE",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "LISTER_ROLE",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "allVaults",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "tuple[]",
        "internalType": "struct PairVaultFactory.VaultRecord[]",
        "components": [
          {
            "name": "vault",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "longAdapter",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "shortAdapter",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "pairId",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "tokenA",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "tokenB",
            "type": "address",
            "internalType": "address"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "createVault",
    "inputs": [
      {
        "name": "spec",
        "type": "tuple",
        "internalType": "struct PairVaultFactory.VaultSpec",
        "components": [
          {
            "name": "tokenA",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "tokenB",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "marketIdA",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "marketIdB",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "window",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "name",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "symbol",
            "type": "string",
            "internalType": "string"
          }
        ]
      }
    ],
    "outputs": [
      {
        "name": "vault",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "longAdapter",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "shortAdapter",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "defaultConfig",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "tuple",
        "internalType": "struct PairVault.Config",
        "components": [
          {
            "name": "maxSlippageBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "deployBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "targetLtvBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "rebalanceLtvBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "maxLtvBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "bandBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "rebalanceTriggerBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "maxTiltBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "maxNotionalUsdg",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "depositCap",
            "type": "uint128",
            "internalType": "uint128"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "defaultManagementFeeBps",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint16",
        "internalType": "uint16"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "defaultPerformanceFeeBps",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint16",
        "internalType": "uint16"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "getRoleAdmin",
    "inputs": [
      {
        "name": "role",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "grantRole",
    "inputs": [
      {
        "name": "role",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "hasRole",
    "inputs": [
      {
        "name": "role",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "longImpl",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "renounceRole",
    "inputs": [
      {
        "name": "role",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "callerConfirmation",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "revokeRole",
    "inputs": [
      {
        "name": "role",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setDefaults",
    "inputs": [
      {
        "name": "c",
        "type": "tuple",
        "internalType": "struct PairVault.Config",
        "components": [
          {
            "name": "maxSlippageBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "deployBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "targetLtvBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "rebalanceLtvBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "maxLtvBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "bandBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "rebalanceTriggerBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "maxTiltBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "maxNotionalUsdg",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "depositCap",
            "type": "uint128",
            "internalType": "uint128"
          }
        ]
      },
      {
        "name": "mgmtBps",
        "type": "uint16",
        "internalType": "uint16"
      },
      {
        "name": "perfBps",
        "type": "uint16",
        "internalType": "uint16"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setShared",
    "inputs": [
      {
        "name": "s",
        "type": "tuple",
        "internalType": "struct PairVaultFactory.Shared",
        "components": [
          {
            "name": "usdg",
            "type": "address",
            "internalType": "contract IERC20"
          },
          {
            "name": "morpho",
            "type": "address",
            "internalType": "contract IMorpho"
          },
          {
            "name": "venue",
            "type": "address",
            "internalType": "contract ISwapVenue"
          },
          {
            "name": "oracle",
            "type": "address",
            "internalType": "contract IPriceOracle"
          },
          {
            "name": "spreadOracle",
            "type": "address",
            "internalType": "contract ISpreadOracle"
          },
          {
            "name": "clock",
            "type": "address",
            "internalType": "contract IMarketClock"
          },
          {
            "name": "engine",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "feeCollector",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "compliance",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "vaultAdmin",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "guardian",
            "type": "address",
            "internalType": "address"
          }
        ]
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "shared",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "tuple",
        "internalType": "struct PairVaultFactory.Shared",
        "components": [
          {
            "name": "usdg",
            "type": "address",
            "internalType": "contract IERC20"
          },
          {
            "name": "morpho",
            "type": "address",
            "internalType": "contract IMorpho"
          },
          {
            "name": "venue",
            "type": "address",
            "internalType": "contract ISwapVenue"
          },
          {
            "name": "oracle",
            "type": "address",
            "internalType": "contract IPriceOracle"
          },
          {
            "name": "spreadOracle",
            "type": "address",
            "internalType": "contract ISpreadOracle"
          },
          {
            "name": "clock",
            "type": "address",
            "internalType": "contract IMarketClock"
          },
          {
            "name": "engine",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "feeCollector",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "compliance",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "vaultAdmin",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "guardian",
            "type": "address",
            "internalType": "address"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "shortImpl",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "supportsInterface",
    "inputs": [
      {
        "name": "interfaceId",
        "type": "bytes4",
        "internalType": "bytes4"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "vaultAt",
    "inputs": [
      {
        "name": "i",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "tuple",
        "internalType": "struct PairVaultFactory.VaultRecord",
        "components": [
          {
            "name": "vault",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "longAdapter",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "shortAdapter",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "pairId",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "tokenA",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "tokenB",
            "type": "address",
            "internalType": "address"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "vaultCount",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "vaultFor",
    "inputs": [
      {
        "name": "tokenA",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "tokenB",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "vault",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "vaultImpl",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "event",
    "name": "DefaultsSet",
    "inputs": [
      {
        "name": "config",
        "type": "tuple",
        "indexed": false,
        "internalType": "struct PairVault.Config",
        "components": [
          {
            "name": "maxSlippageBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "deployBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "targetLtvBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "rebalanceLtvBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "maxLtvBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "bandBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "rebalanceTriggerBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "maxTiltBps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "maxNotionalUsdg",
            "type": "uint128",
            "internalType": "uint128"
          },
          {
            "name": "depositCap",
            "type": "uint128",
            "internalType": "uint128"
          }
        ]
      },
      {
        "name": "managementFeeBps",
        "type": "uint16",
        "indexed": false,
        "internalType": "uint16"
      },
      {
        "name": "performanceFeeBps",
        "type": "uint16",
        "indexed": false,
        "internalType": "uint16"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "RoleAdminChanged",
    "inputs": [
      {
        "name": "role",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "previousAdminRole",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "newAdminRole",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "RoleGranted",
    "inputs": [
      {
        "name": "role",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "account",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "sender",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "RoleRevoked",
    "inputs": [
      {
        "name": "role",
        "type": "bytes32",
        "indexed": true,
        "internalType": "bytes32"
      },
      {
        "name": "account",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "sender",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "SharedSet",
    "inputs": [
      {
        "name": "shared",
        "type": "tuple",
        "indexed": false,
        "internalType": "struct PairVaultFactory.Shared",
        "components": [
          {
            "name": "usdg",
            "type": "address",
            "internalType": "contract IERC20"
          },
          {
            "name": "morpho",
            "type": "address",
            "internalType": "contract IMorpho"
          },
          {
            "name": "venue",
            "type": "address",
            "internalType": "contract ISwapVenue"
          },
          {
            "name": "oracle",
            "type": "address",
            "internalType": "contract IPriceOracle"
          },
          {
            "name": "spreadOracle",
            "type": "address",
            "internalType": "contract ISpreadOracle"
          },
          {
            "name": "clock",
            "type": "address",
            "internalType": "contract IMarketClock"
          },
          {
            "name": "engine",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "feeCollector",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "compliance",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "vaultAdmin",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "guardian",
            "type": "address",
            "internalType": "address"
          }
        ]
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "VaultCreated",
    "inputs": [
      {
        "name": "vault",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "pairId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "tokenA",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      },
      {
        "name": "tokenB",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      },
      {
        "name": "longAdapter",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      },
      {
        "name": "shortAdapter",
        "type": "address",
        "indexed": false,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "AccessControlBadConfirmation",
    "inputs": []
  },
  {
    "type": "error",
    "name": "AccessControlUnauthorizedAccount",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "neededRole",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ]
  },
  {
    "type": "error",
    "name": "BadParam",
    "inputs": []
  },
  {
    "type": "error",
    "name": "FailedDeployment",
    "inputs": []
  },
  {
    "type": "error",
    "name": "InsufficientBalance",
    "inputs": [
      {
        "name": "balance",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "needed",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "PairExists",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ReentrancyGuardReentrantCall",
    "inputs": []
  }
] as const;
