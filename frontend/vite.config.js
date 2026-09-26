import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { defineConfig, loadEnv } from 'vite';

const __dirname = fileURLToPath(new URL('.', import.meta.url));
const ZERO = '0x0000000000000000000000000000000000000000';

// Chain defaults; token addresses can be overridden via AQUA_TOKEN_* in .env.
const CHAIN_DEFAULTS = {
  ethereum: {
    chainId: 1, name: 'Ethereum', currency: 'ETH', rpcEnv: 'ETH_RPC_URL',
    rpc: 'https://ethereum-rpc.publicnode.com', explorer: 'https://etherscan.io',
    tokens: { usdt: ZERO, weth: ZERO, wbtc: ZERO },
  },
  sepolia: {
    chainId: 11155111, name: 'Sepolia', currency: 'ETH', rpcEnv: 'SEPOLIA_RPC_URL',
    rpc: 'https://ethereum-sepolia-rpc.publicnode.com', explorer: 'https://sepolia.etherscan.io',
    tokens: {
      usdt: '0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238',
      weth: '0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9',
      wbtc: '0xE47dE7c2c4d24198Ff8f3bC3a1d3C529c67925BD',
    },
  },
  base: {
    chainId: 8453, name: 'Base', currency: 'ETH', rpcEnv: 'BASE_RPC_URL',
    rpc: 'https://mainnet.base.org', explorer: 'https://basescan.org',
    tokens: {
      usdt: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913',
      weth: '0x4200000000000000000000000000000000000006',
      wbtc: '0x1ceA84203673764244E05693e42E6Ace62bE9BA5',
    },
  },
  optimism: {
    chainId: 10, name: 'Optimism', currency: 'ETH', rpcEnv: 'OPTIMISM_RPC_URL',
    rpc: 'https://mainnet.optimism.io', explorer: 'https://optimistic.etherscan.io',
    tokens: { usdt: ZERO, weth: '0x4200000000000000000000000000000000000006', wbtc: ZERO },
  },
  arbitrum: {
    chainId: 42161, name: 'Arbitrum One', currency: 'ETH', rpcEnv: 'ARBITRUM_RPC_URL',
    rpc: 'https://arb1.arbitrum.io/rpc', explorer: 'https://arbiscan.io',
    tokens: { usdt: ZERO, weth: ZERO, wbtc: ZERO },
  },
};

// address:chain:from_block[:maturities] — reuse the server's first app entry.
function firstApp(raw) {
  for (const item of (raw || '').split(';')) {
    const parts = item.trim().split(':');
    if (parts.length >= 3) {
      return { app: parts[0].trim().toLowerCase(), chain: parts[1].trim().toLowerCase() };
    }
  }
  return { app: '', chain: '' };
}

function buildAquaEnv(env) {
  const first = firstApp(env.AQUATERM_APPS);
  const chain = (env.AQUA_CHAIN || first.chain || 'ethereum').toLowerCase();
  const app = (env.AQUA_APP_ADDRESS || first.app || '').toLowerCase();
  const def = CHAIN_DEFAULTS[chain] || CHAIN_DEFAULTS.ethereum;
  const token = (sym) => (env[`AQUA_TOKEN_${sym.toUpperCase()}`] || def.tokens[sym] || ZERO).toLowerCase();
  const usdt = token('usdt'), weth = token('weth'), wbtc = token('wbtc');
  return {
    apiBase: (env.AQUA_API_BASE || 'http://127.0.0.1:5001/api').replace(/\/+$/, ''),
    chain,
    appAddress: app,
    chains: {
      [chain]: {
        key: chain,
        chainId: def.chainId,
        name: def.name,
        currency: def.currency,
        rpcUrl: env[def.rpcEnv] || def.rpc,
        explorer: def.explorer,
      },
    },
    contracts: {
      [chain]: {
        app,
        debtToken: (env.AQUA_DEBT_TOKEN || usdt).toLowerCase(),
        tokens: { usdt, weth, wbtc },
      },
    },
  };
}

export default defineConfig(({ mode }) => {
  // Load the repo-root .env (all keys; only the public subset below is injected).
  const env = loadEnv(mode, resolve(__dirname, '..'), '');
  const aquaEnv = buildAquaEnv(env);
  return {
    root: __dirname,
    server: { port: 5173 },
    build: { outDir: 'dist', emptyOutDir: true },
    plugins: [
      {
        name: 'aqua-env-inject',
        transformIndexHtml() {
          return [
            {
              tag: 'script',
              children: `window.AquaEnv=${JSON.stringify(aquaEnv)};`,
              injectTo: 'head-prepend',
            },
          ];
        },
      },
    ],
  };
});
