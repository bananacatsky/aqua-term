/* Small ethers v6 helpers used by the static frontend. */
(function(){
  let provider;
  let signer;
  let activeTransaction=false;

  function ensureTransactionUi(){
    let root=document.getElementById('aqua-transaction-ui');
    if(root) return root;
    root=document.createElement('div');
    root.id='aqua-transaction-ui';
    root.className='aqua-tx-overlay';
    root.hidden=true;
    root.innerHTML=`
      <div class="aqua-tx-dialog" role="status" aria-live="polite">
        <div class="aqua-tx-spinner" data-tx-spinner></div>
        <div class="aqua-tx-title" data-tx-title>Transaction</div>
        <div class="aqua-tx-message" data-tx-message></div>
        <a class="aqua-tx-hash" data-tx-hash target="_blank" rel="noopener"></a>
        <button class="aqua-tx-close" data-tx-close type="button" hidden>Close</button>
      </div>`;
    document.body.appendChild(root);
    root.querySelector('[data-tx-close]').addEventListener('click',()=>{
      if(!activeTransaction) root.hidden=true;
    });
    return root;
  }

  function updateTransactionUi({title,message,state='pending',hash,chainKey}){
    const root=ensureTransactionUi();
    root.hidden=false;
    root.dataset.state=state;
    root.querySelector('[data-tx-title]').textContent=title;
    root.querySelector('[data-tx-message]').textContent=message;
    root.querySelector('[data-tx-spinner]').hidden=state!=='pending';
    const close=root.querySelector('[data-tx-close]');
    close.hidden=state==='pending';
    const hashLink=root.querySelector('[data-tx-hash]');
    hashLink.textContent=hash?'View transaction':' '; 
    hashLink.href=hash?`${AquaConfig.AquaChains[chainKey]?.explorer||''}/tx/${hash}`:'#';
  }

  function readableError(error){
    const raw=[error?.shortMessage,error?.reason,error?.message,error?.data?.message,error?.info?.error?.message]
      .filter(Boolean).join(' ');
    const normalized=raw.toLowerCase();
    if(normalized.includes('insufficient_collateral') || normalized.includes('insufficient collateral')){
      return 'Insufficient deposited collateral. Reduce the withdrawal amount or repay debt first.';
    }
    if(normalized.includes('unhealthy')){
      return 'This withdrawal would make your collateral position unhealthy.';
    }
    if(normalized.includes('insufficient_wallet_collateral')){
      return 'Your wallet does not have enough collateral for this operation.';
    }
    if(normalized.includes('zero_order') || normalized.includes('zero_fill')){
      return 'Order amounts must be greater than zero.';
    }
    if(normalized.includes('bad_order_ltv') || normalized.includes('borrower_ltv') || normalized.includes('protocol_ltv')){
      return 'This fill would exceed the allowed LTV. Deposit more collateral or lower the amount.';
    }
    if(normalized.includes('unsupported_maturity')){
      return 'This maturity is not supported by the deployed app.';
    }
    if(normalized.includes('order_expired') || normalized.includes('cancelled')){
      return 'One of the orders is cancelled or expired.';
    }
    if(normalized.includes('borrow_overfill') || normalized.includes('supply_overfill')){
      return 'The fill size is larger than the remaining order size.';
    }
    if(normalized.includes('borrow_price') || normalized.includes('supply_price')){
      return 'These orders no longer cross at the requested fill size.';
    }
    if(normalized.includes('not_borrower') || normalized.includes('not_supplier')){
      return 'Only the order maker can cancel this order.';
    }
    if(normalized.includes('too_much')){
      return 'The amount is larger than the outstanding position.';
    }
    if(normalized.includes('not_matured')){
      return 'This vault can be redeemed only after maturity.';
    }
    if(normalized.includes('insufficient_cash')){
      return 'The vault does not have enough cash to redeem that amount yet.';
    }
    if(normalized.includes('user rejected') || normalized.includes('action_rejected')){
      return 'You rejected the request';
    }
    return raw||'Unknown blockchain error';
  }

  async function executeTransaction({label='Transaction',chainKey=AquaConfig.AQUA_CHAIN,action}){
    if(activeTransaction) throw new Error('Another transaction is already in progress');
    activeTransaction=true;
    updateTransactionUi({title:label,message:'Confirm the transaction in your wallet',chainKey});
    try{
      const submitted=await action();
      if(submitted?.hash){
        updateTransactionUi({title:label,message:'Transaction submitted. Waiting for confirmation…',state:'pending',hash:submitted.hash,chainKey});
      }
      const receipt=submitted?.wait ? await submitted.wait() : submitted;
      updateTransactionUi({title:'Transaction complete',message:`${label} completed successfully`,state:'success',hash:receipt?.hash||submitted?.hash,chainKey});
      return receipt;
    }catch(error){
      const rejected=error?.code===4001 || error?.code==='ACTION_REJECTED';
      updateTransactionUi({title:rejected?'Transaction cancelled':'Transaction failed',message:rejected?'You rejected the request':readableError(error),state:'error',chainKey});
      throw error;
    }finally{
      activeTransaction=false;
    }
  }

  function getChainConfig(chainKey=AquaConfig.AQUA_CHAIN){
    const chain=AquaConfig.AquaChains[chainKey];
    if(!chain) throw new Error(`Unknown chain: ${chainKey}`);
    return chain;
  }

  function getAddress(contractKey,chainKey=AquaConfig.AQUA_CHAIN){
    const contracts=AquaConfig.AquaContracts[chainKey];
    const address=contracts?.[contractKey] || (contractKey==='aqua' ? AquaConfig.AQUA_REGISTRY : undefined);
    if(!address || address===AquaConfig.ZERO_ADDRESS){
      throw new Error(`Contract address is not configured: ${chainKey}.${contractKey}`);
    }
    return address;
  }

  async function ensureChain(chainKey=AquaConfig.AQUA_CHAIN){
    const chain=getChainConfig(chainKey);
    const network=await getProvider().getNetwork();
    if(Number(network.chainId)===Number(chain.chainId)) return;
    const chainId='0x'+Number(chain.chainId).toString(16);
    try{
      await getProvider().send('wallet_switchEthereumChain',[{chainId}]);
    }catch(error){
      if(error?.code!==4902) throw error;
      await getProvider().send('wallet_addEthereumChain',[{
        chainId,
        chainName:chain.name,
        nativeCurrency:{name:chain.currency,symbol:chain.currency,decimals:18},
        rpcUrls:[chain.rpcUrl],
        blockExplorerUrls:chain.explorer?[chain.explorer]:[],
      }]);
    }
    if(provider) signer=await provider.getSigner();
  }

  function parseEvent(receipt,abi,eventName){
    const iface=new ethers.Interface(abi);
    for(const log of receipt?.logs||[]){
      try{
        const parsed=iface.parseLog({topics:log.topics,data:log.data});
        if(parsed?.name===eventName) return parsed;
      }catch{
        // ignore logs from other contracts
      }
    }
    return null;
  }

  async function ensureAllowance({token,spender,amount,symbol='token',chainKey=AquaConfig.AQUA_CHAIN}){
    if(!signer) throw new Error('Wallet is not connected');
    const owner=await signer.getAddress();
    const current=await readContract({
      address:token,
      abi:AquaConfig.AquaABIs.erc20,
      functionName:'allowance',
      args:[owner,spender],
      chainKey,
    });
    if(BigInt(current)>=BigInt(amount)) return false;
    await writeContract({
      address:token,
      abi:AquaConfig.AquaABIs.erc20,
      functionName:'approve',
      args:[spender,ethers.MaxUint256],
      chainKey,
      label:`Approve ${symbol}`,
    });
    return true;
  }

  function setWalletProvider(nextProvider,nextSigner){
    provider=nextProvider;
    signer=nextSigner;
  }

  function getProvider(){
    if(!provider) throw new Error('Wallet is not connected');
    return provider;
  }

  function getContract({contractKey,address,abi,chainKey=AquaConfig.AQUA_CHAIN,write=false}){
    const contractAddress=address||getAddress(contractKey,chainKey);
    const runner=write ? signer : (provider||new ethers.JsonRpcProvider(getChainConfig(chainKey).rpcUrl));
    if(write && !signer) throw new Error('Wallet is not connected');
    return new ethers.Contract(contractAddress,abi,runner);
  }

  async function readContract({contractKey,address,abi,functionName,args=[],chainKey=AquaConfig.AQUA_CHAIN}){
    const contract=getContract({contractKey,address,abi,chainKey});
    return contract[functionName](...args);
  }

  async function simulateContract({contractKey,address,abi,functionName,args=[],overrides={},chainKey=AquaConfig.AQUA_CHAIN}){
    const contract=getContract({contractKey,address,abi,chainKey});
    const data=contract.interface.encodeFunctionData(functionName,args);
    const result=await getProvider().call({to:contract.target,data,...overrides});
    return contract.interface.decodeFunctionResult(functionName,result);
  }

  async function writeContract({contractKey,address,abi,functionName,args=[],overrides={},chainKey=AquaConfig.AQUA_CHAIN,wait=true,label=functionName}){
    const send=async()=>{
      await ensureChain(chainKey);
      const contract=getContract({contractKey,address,abi,chainKey,write:true});
      const from=await signer.getAddress();
      // Run the exact call as a read first, so wallet confirmation is only shown
      // when the transaction is expected to succeed.
      await getProvider().call({to:contract.target,data:contract.interface.encodeFunctionData(functionName,args),from,...overrides});
      return contract[functionName](...args,overrides);
    };
    if(wait) return executeTransaction({
      label,
      chainKey,
      action:send,
    });
    return send();
  }

  function formatTokenAmount(value,decimals=18,options={}){
    if(value===null || value===undefined) return '—';
    return ethers.formatUnits(value,decimals,options);
  }

  function parseTokenAmount(value,decimals=18){
    return ethers.parseUnits(String(value).trim(),decimals);
  }

  function tokenAmount(value,tokenKey){
    const token=AquaConfig.AquaTokens[tokenKey];
    if(!token) throw new Error(`Unknown token: ${tokenKey}`);
    return parseTokenAmount(value,token.decimals);
  }

  function formatToken(value,tokenKey){
    const token=AquaConfig.AquaTokens[tokenKey];
    if(!token) throw new Error(`Unknown token: ${tokenKey}`);
    return `${formatTokenAmount(value,token.decimals)} ${token.symbol}`;
  }

  window.AquaTx={executeTransaction,isBusy:()=>activeTransaction};
  window.AquaWeb3={setWalletProvider,getProvider,getAddress,getContract,readContract,simulateContract,writeContract,ensureChain,ensureAllowance,parseEvent,formatTokenAmount,parseTokenAmount,tokenAmount,formatToken,readableError};
})();
