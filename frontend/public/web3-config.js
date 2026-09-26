/*
 * Frontend Web3 configuration (ABIs, maturities, chain defaults).
 * Deployment-specific values come from env-config.js (see scripts/gen_frontend_config.py).
 */
const ZERO_ADDRESS='0x0000000000000000000000000000000000000000';

const AquaChains={
  ethereum:{
    key:'ethereum', chainId:1, name:'Ethereum', currency:'ETH',
    rpcUrl:'https://ethereum-rpc.publicnode.com', explorer:'https://etherscan.io',
  },
  sepolia:{
    key:'sepolia', chainId:11155111, name:'Sepolia', currency:'ETH',
    rpcUrl:'https://ethereum-sepolia-rpc.publicnode.com', explorer:'https://sepolia.etherscan.io',
  },
  base:{
    key:'base', chainId:8453, name:'Base', currency:'ETH',
    rpcUrl:'https://mainnet.base.org', explorer:'https://basescan.org',
  },
  optimism:{
    key:'optimism', chainId:10, name:'Optimism', currency:'ETH',
    rpcUrl:'https://mainnet.optimism.io', explorer:'https://optimistic.etherscan.io',
  },
  arbitrum:{
    key:'arbitrum', chainId:42161, name:'Arbitrum One', currency:'ETH',
    rpcUrl:'https://arb1.arbitrum.io/rpc', explorer:'https://arbiscan.io',
  },
};

// Overridden by window.AquaEnv.chain when env-config.js is present.
let AQUA_CHAIN='ethereum';

const AquaContracts={
  ethereum:{
    app:ZERO_ADDRESS,
    debtToken:ZERO_ADDRESS,
    tokens:{usdt:ZERO_ADDRESS,weth:ZERO_ADDRESS,wbtc:ZERO_ADDRESS},
  },
  sepolia:{
    app:ZERO_ADDRESS,
    debtToken:ZERO_ADDRESS,
    tokens:{usdt:ZERO_ADDRESS,weth:ZERO_ADDRESS,wbtc:ZERO_ADDRESS},
  },
  base:{
    app:ZERO_ADDRESS,
    debtToken:ZERO_ADDRESS,
    tokens:{usdt:ZERO_ADDRESS,weth:ZERO_ADDRESS,wbtc:ZERO_ADDRESS},
  },
  optimism:{
    app:ZERO_ADDRESS,
    debtToken:ZERO_ADDRESS,
    tokens:{usdt:ZERO_ADDRESS,weth:ZERO_ADDRESS,wbtc:ZERO_ADDRESS},
  },
  arbitrum:{
    app:ZERO_ADDRESS,
    debtToken:ZERO_ADDRESS,
    tokens:{usdt:ZERO_ADDRESS,weth:ZERO_ADDRESS,wbtc:ZERO_ADDRESS},
  },
};

const AquaTokens={
  usdt:{symbol:'USDT',decimals:6},
  weth:{symbol:'WETH',decimals:18},
  wbtc:{symbol:'WBTC',decimals:8},
};

// Maturity timestamps must match vaults created in AquaTermApp.
const AquaMaturities=[
  {key:'oct-30-2026',label:'OCT 30',timestamp:Date.parse('2026-10-30T00:00:00Z')/1000},
  {key:'nov-30-2026',label:'NOV 30',timestamp:Date.parse('2026-11-30T00:00:00Z')/1000},
  {key:'dec-31-2026',label:'DEC 31',timestamp:Date.parse('2026-12-31T00:00:00Z')/1000},
  {key:'jan-31-2027',label:'JAN 31',timestamp:Date.parse('2027-01-31T00:00:00Z')/1000},
];

const AquaABIs={
  app:[
    'function depositCollateral(uint256 collateralId,uint256 amount)',
    'function withdrawCollateral(uint256 collateralId,uint256 amount)',
    'function depositedCollateral(address,uint256) view returns (uint256)',
    'function collateralValue(address borrower) view returns (uint256)',
    'function portfolioWeightedMaxBorrowLtv(address borrower) view returns (uint256)',
    'function portfolioWeightedLiquidationLtv(address borrower) view returns (uint256)',
    'function healthFactor(address borrower) view returns (uint256)',
    'function currentLtv(address borrower) view returns (uint256)',
    'function createBorrowOrder(uint40 maturity,uint128 faceAmount,uint128 minDebtTokenOut,uint16 ltvBps,uint256 collateralId,uint40 deadline) returns (uint256 orderId,bytes32 strategyHash)',
    'function createSupplyOrder(uint40 maturity,uint128 debtTokenIn,uint128 minTermOut,uint40 deadline) returns (uint256 orderId,bytes32 strategyHash)',
    'function cancelBorrowOrder(uint256 id)',
    'function cancelSupplyOrder(uint256 id)',
    'function matchOrders(uint256 borrowOrderId,uint256 supplyOrderId,uint256 faceAmount,uint256 debtTokenAmount)',
    'function repay(uint40 maturity,uint256 amount)',
    'function borrowOrders(uint256) view returns (address borrower,uint40 maturity,uint40 deadline,uint128 faceAmount,uint128 minDebtTokenOut,uint16 ltvBps,uint256 collateralId,uint128 filledFace,bool cancelled)',
    'function supplyOrders(uint256) view returns (address supplier,uint40 maturity,uint40 deadline,uint128 debtTokenIn,uint128 minTermOut,uint128 filledDebtToken,bool cancelled)',
  ],
  erc20:[
    'function name() view returns (string)',
    'function symbol() view returns (string)',
    'function decimals() view returns (uint8)',
    'function balanceOf(address) view returns (uint256)',
    'function allowance(address owner,address spender) view returns (uint256)',
    'function approve(address spender,uint256 amount) returns (bool)',
    'function transfer(address to,uint256 amount) returns (bool)',
  ],
  vault:[
    'function totalAssets() view returns (uint256)',
    'function balanceOf(address) view returns (uint256)',
    'function previewDebtShares(uint256 faceAmount) view returns (uint256)',
    'function redeem(uint256 shares,address receiver,address owner) returns (uint256 assets)',
  ],
};

(function applyAquaEnv(){
  const env=window.AquaEnv;
  if(!env) return;
  if(env.chain) AQUA_CHAIN=env.chain;
  if(env.chains){
    Object.entries(env.chains).forEach(([key,cfg])=>{
      AquaChains[key]={...AquaChains[key],key,...cfg};
    });
  }
  if(env.contracts){
    Object.entries(env.contracts).forEach(([key,cfg])=>{
      AquaContracts[key]={
        ...AquaContracts[key],
        ...cfg,
        tokens:{...AquaContracts[key]?.tokens,...cfg.tokens},
      };
    });
  }
})();

window.AquaConfig={ZERO_ADDRESS,AquaChains,get AQUA_CHAIN(){return AQUA_CHAIN},AquaContracts,AquaTokens,AquaMaturities,AquaABIs};
