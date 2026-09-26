const _aquaEnv=window.AquaEnv||{};
const AquaApi={
  baseUrl:_aquaEnv.apiBase||window.AQUA_API_BASE||'http://127.0.0.1:5001/api',
  appAddress:(_aquaEnv.appAddress||'0x0000000000000000000000000000000000000abc').toLowerCase(),
  chain:_aquaEnv.chain||'ethereum',
  requestId:0,
  market:null,
  portfolio:null,
  currentAddress:null,

  async request(path,params={}){
    const base=this.baseUrl.replace(/\/+$/,'');
    const url=new URL(`${base}/${path.replace(/^\//,'')}`,window.location.origin);
    Object.entries(params).forEach(([key,value])=>{if(value!==undefined&&value!==null)url.searchParams.set(key,value)});
    let response;
    try{
      response=await fetch(url);
    }catch(error){
      throw new Error(`API unreachable (${url.origin}${url.pathname})`);
    }
    let payload;
    try{
      payload=await response.json();
    }catch{
      throw new Error(`API returned non-JSON (${response.status})`);
    }
    if(!response.ok) throw new Error(payload.error||`API request failed (${response.status})`);
    return payload;
  },

  async loadOrderbooks(params,maturities){
    return Promise.all((maturities||[]).map(async item=>{
      try{
        return await this.request('orderbook',{...params,maturity:item.timestamp});
      }catch(error){
        console.warn('Orderbook unavailable',item.timestamp,error);
        return {maturity:item.timestamp,buy:{items:[]},sell:{items:[]}};
      }
    }));
  },

  async loadForAddress(address){
    if(!address) throw new Error('Wallet address is required');
    const requestId=++this.requestId;
    const params={app:this.appAddress,chain:this.chain,address};
    const market=await this.request('market',params);
    const [portfolio,orders,orderbooks]=await Promise.all([
      this.request('portfolio',params),
      this.request('orders',{app:params.app,chain:params.chain,maker:address}),
      this.loadOrderbooks(params,market.maturities),
    ]);
    if(requestId!==this.requestId) return null;
    this.market=market;
    this.portfolio=portfolio;
    this.currentAddress=address;
    this.renderMarket(market);
    const createOrder=document.getElementById('create-order');
    if(createOrder) createOrder.classList.remove('wallet-disconnected');
    this.renderPortfolio(portfolio);
    await Promise.all(orderbooks.map(item=>this.renderOrderbook(item,true)));
    this.renderOpenOrders(orders);
    const status=document.getElementById('api-status');
    if(status){status.textContent='API: connected';status.className='api-status online'}
    return {market,portfolio,orders,orderbooks};
  },

  async loadPublicData(){
    const requestId=++this.requestId;
    const params={app:this.appAddress,chain:this.chain};
    const market=await this.request('market',params);
    const orderbooks=await this.loadOrderbooks(params,market.maturities);
    if(requestId!==this.requestId) return null;
    this.market=market;
    this.renderMarket(market);
    await Promise.all(orderbooks.map(item=>this.renderOrderbook(item)));
    const status=document.getElementById('api-status');
    if(status){status.textContent='API: public data';status.className='api-status online'}
    return {market,orderbooks};
  },

  configuredDebtToken(){
    const chain=window.AquaEnv?.chain||window.AquaConfig?.AQUA_CHAIN;
    const contracts=window.AquaConfig?.AquaContracts?.[chain]||{};
    const debtAddr=String(contracts.debtToken||'').toLowerCase();
    const tokens=contracts.tokens||{};
    const key=Object.keys(tokens).find(item=>String(tokens[item]||'').toLowerCase()===debtAddr);
    const meta=key&&window.AquaConfig?.AquaTokens?.[key];
    if(meta) return {symbol:meta.symbol,decimals:meta.decimals,address:tokens[key]};
    const usdt=window.AquaConfig?.AquaTokens?.usdt;
    return usdt?{symbol:usdt.symbol,decimals:usdt.decimals}:{symbol:'USDT',decimals:6};
  },

  debtToken(){
    return this.market?.debt_token||this.configuredDebtToken();
  },

  debtSymbol(){
    return this.debtToken().symbol||this.configuredDebtToken().symbol||'USDT';
  },

  isEthLikeCollateral(symbol){
    return /ETH/i.test(String(symbol||''));
  },

  debtDecimals(){
    return Number(this.debtToken().decimals??6);
  },

  maturityLabel(timestamp){
    return this.market?.maturities?.find(item=>Number(item.timestamp)===Number(timestamp))?.label||timestamp;
  },

  formatDebt(amount,opts={}){
    const value=Number(amount||0)/10**this.debtDecimals();
    const digits=opts.digits??2;
    return `${value.toLocaleString('en-US',{maximumFractionDigits:digits})} ${this.debtSymbol()}`;
  },

  formatUsdFromDebt(amount){
    const value=Number(amount||0)/10**this.debtDecimals();
    return `$${value.toLocaleString('en-US',{maximumFractionDigits:2})}`;
  },

  formatTokenAmount(amount,decimals,symbol){
    const value=Number(amount||0)/10**Number(decimals||0);
    const digits=Number(decimals)>=8?3:Number(decimals)>=6?2:4;
    return `${value.toLocaleString('en-US',{maximumFractionDigits:digits})} ${symbol}`;
  },

  formatHealthFactor(risk){
    const raw=risk?.health_factor;
    if(risk?.health_status==='no_debt' || raw==null || raw==='' || raw==='no_debt' || raw==='no-debt') return '∞';
    return String(raw);
  },

  formatHealthStatus(status){
    if(status==='no_debt') return 'No debt';
    if(!status) return '';
    return String(status).replace(/_/g,' ');
  },

  isZeroAmount(value){
    if(value==null || value==='') return true;
    try{ return BigInt(value)===0n; }
    catch{ return Number(value)===0; }
  },

  hasNonZero(items, pick){
    return (items||[]).some(item=>{
      const value=typeof pick==='function'?pick(item):item?.[pick];
      return !this.isZeroAmount(value);
    });
  },

  setSectionHidden(id, hidden){
    const el=document.getElementById(id);
    if(el) el.hidden=!!hidden;
  },

  clearDashboard(){
    this.requestId+=1;
    this.market=null;
    this.portfolio=null;
    this.currentAddress=null;
    const portfolio=document.getElementById('portfolio');
    if(portfolio) portfolio.classList.add('wallet-disconnected');
    const createOrder=document.getElementById('create-order');
    if(createOrder) createOrder.classList.add('wallet-disconnected');
    ['wallet-balance-value','debt-value','collateral-value','health-factor-value','current-ltv-value','borrow-limit-value','liquidation-limit-value','health-factor-risk-value'].forEach(id=>{
      const el=document.getElementById(id); if(el) el.textContent='';
    });
    ['debts-list','lending-list','collateral-list','wallet-list','open-orders-list'].forEach(id=>{
      const el=document.getElementById(id); if(el) el.replaceChildren();
    });
    const maturitySelect=document.getElementById('maturity-select');
    if(maturitySelect) maturitySelect.replaceChildren();
    const collateralSelect=document.getElementById('order-collateral-select')||document.querySelector('#borrow-fields select');
    if(collateralSelect) collateralSelect.replaceChildren();
    ['deposit-token-select','withdraw-token-select'].forEach(id=>{
      const select=document.getElementById(id);
      if(select) select.replaceChildren();
    });
    ['deposit-token-balance','withdraw-token-balance'].forEach(id=>{
      const el=document.getElementById(id); if(el) el.textContent='';
    });
    document.querySelectorAll('.maturity-tab').forEach(tab=>{tab.textContent='';tab.hidden=false;});
    document.querySelectorAll('#portfolio > .grid, #portfolio > .card').forEach(section=>{section.hidden=true;});
    const portfolioHead=document.querySelector('#portfolio > .page-head');
    if(portfolioHead) portfolioHead.hidden=true;
    const message=document.getElementById('portfolio-connect-message');
    if(message) message.style.display='flex';
  },

  renderMarket(data){
    const maturitySelect=document.getElementById('maturity-select');
    if(maturitySelect) maturitySelect.innerHTML=data.maturities.map(item=>`<option value="${item.timestamp}">${item.label}</option>`).join('');
    const collateralSelect=document.getElementById('order-collateral-select')||document.querySelector('#borrow-fields select');
    if(collateralSelect){
      const previous=collateralSelect.value;
      collateralSelect.innerHTML=(data.collaterals||[]).map(item=>`<option value="${item.id}">${item.symbol}</option>`).join('');
      const keep=previous&&(data.collaterals||[]).some(item=>String(item.id)===String(previous));
      const ethLike=(data.collaterals||[]).find(item=>this.isEthLikeCollateral(item.symbol));
      if(keep) collateralSelect.value=previous;
      else if(ethLike) collateralSelect.value=String(ethLike.id);
    }
    this.fillCollateralSelects(data.collaterals);
    const debt=data.debt_token?.symbol||this.debtSymbol();
    const walletHint=document.getElementById('wallet-balance-hint');
    if(walletHint) walletHint.textContent=[debt,...data.collaterals.map(item=>item.symbol)].filter(Boolean).join(' + ');
    const lendNote=document.getElementById('lend-wallet-note');
    if(lendNote) lendNote.textContent=`Your ${debt} stays in your wallet until a compatible borrower is matched.`;
    document.querySelectorAll('[data-debt-symbol]').forEach(el=>{el.textContent=debt});
    this.renderMaturityTabs(data.maturities);
  },

  renderMaturityTabs(maturities){
    const tabs=document.querySelector('.maturity-tabs');
    const ladder=document.querySelector('.card.ladder');
    if(!tabs||!ladder) return;
    const selected=document.querySelector('.maturity-tab.active')?.dataset.month;
    const keep=maturities.some(item=>String(item.timestamp)===selected)?selected:String(maturities[0]?.timestamp||'');
    tabs.replaceChildren();
    ladder.querySelectorAll('.month-panel').forEach(panel=>panel.remove());
    maturities.forEach(item=>{
      const key=String(item.timestamp);
      const tab=document.createElement('button');
      tab.type='button';
      tab.className=`maturity-tab${key===keep?' active':''}`;
      tab.dataset.month=key;
      tab.textContent=item.label;
      tabs.appendChild(tab);
      const panel=document.createElement('div');
      panel.className=`month-panel${key===keep?' active':''}`;
      panel.dataset.panel=key;
      ladder.appendChild(panel);
    });
  },

  renderPortfolio(data){
    const portfolio=document.getElementById('portfolio');
    if(portfolio) portfolio.classList.remove('wallet-disconnected');
    document.querySelectorAll('#portfolio > .grid, #portfolio > .card').forEach(section=>{section.hidden=false;});
    const portfolioHead=document.querySelector('#portfolio > .page-head');
    if(portfolioHead) portfolioHead.hidden=false;
    const message=document.getElementById('portfolio-connect-message');
    if(message) message.style.display='none';
    const set=(id,value)=>{const el=document.getElementById(id);if(el)el.textContent=value};
    const usdCents=v=>`$${(Number(v)/100).toLocaleString('en-US',{maximumFractionDigits:2})}`;
    set('wallet-balance-value',data.wallet_value_usd_cents==null?'':usdCents(data.wallet_value_usd_cents));
    set('debt-value',this.formatDebt(data.risk.total_debt));
    set('collateral-value',this.formatUsdFromDebt(data.risk.collateral_value));
    set('health-factor-value',this.formatHealthFactor(data.risk));
    set('current-ltv-value',`${(data.risk.current_ltv_bps/100).toFixed(1)}%`);
    set('borrow-limit-value',`${(data.risk.max_borrow_ltv_bps/100).toFixed(0)}%`);
    set('liquidation-limit-value',`${(data.risk.liquidation_ltv_bps/100).toFixed(0)}%`);
    set('health-factor-risk-value',this.formatHealthFactor(data.risk));
    const statusClass=data.risk.health_status==='unhealthy'?'gray':(data.risk.health_status==='healthy'||data.risk.health_status==='no_debt'?'green':'orange');
    ['health-status-pill','health-status-section'].forEach(id=>{const el=document.getElementById(id);if(el){el.className=`pill ${statusClass}`;el.textContent=this.formatHealthStatus(data.risk.health_status);}});
    set('health-description',data.risk.health_message||'');
    const riskbar=document.getElementById('riskbar-value');
    if(riskbar) riskbar.style.width=`${Math.max(0,Math.min(100,Number(data.risk.risk_percent||0)))}%`;
    const noDebt=data.risk.health_status==='no_debt' || this.isZeroAmount(data.risk.total_debt);
    this.setSectionHidden('borrowing-health', noDebt);
    this.setSectionHidden('collateral-panel', !this.hasNonZero(data.collateral,'amount'));
    this.setSectionHidden('wallet-panel', !this.hasNonZero(data.wallet,'amount'));
    const collateralHidden=document.getElementById('collateral-panel')?.hidden;
    const walletHidden=document.getElementById('wallet-panel')?.hidden;
    this.setSectionHidden('balances-grid', !!(collateralHidden && walletHidden));
    this.updateDepositBalance();

    const debts=document.getElementById('debts-list');
    if(debts) debts.innerHTML=data.debts.length?data.debts.map(item=>`<div class="position-row"><div><div class="num">Debt · ${item.label}</div><div class="muted">Fixed maturity</div></div><div><div class="num">${this.formatDebt(item.face_debt)}</div><div class="muted">Outstanding</div></div><div><div class="num">${this.formatDebt(item.written_down)}</div><div class="muted">Written down</div></div><button class="btn btn-primary" type="button" data-repay-maturity="${item.maturity}" data-repay-amount="${item.face_debt}">Repay</button></div>`).join(''):'<div class="muted">No active debts.</div>';
    const lending=document.getElementById('lending-list');
    if(lending) lending.innerHTML=data.lending.length?data.lending.map(item=>{
      const canRedeem=!this.isZeroAmount(item.redeemable_shares);
      const redeemBtn=canRedeem
        ? `<button class="btn btn-primary" type="button" data-redeem-vault="${item.vault}" data-redeem-shares="${item.redeemable_shares}">Redeem</button>`
        : `<button class="btn btn-secondary" type="button" disabled title="Redeemable after maturity when the vault has cash">Redeem</button>`;
      return `<div class="position-row"><div><div class="num">${item.label}</div><div class="muted">Fixed maturity</div></div><div><div class="num">${this.formatDebt(item.assets)}</div><div class="muted">Lent now</div></div><div><div class="num">${this.formatDebt(item.redeemable_assets)}</div><div class="muted">Redeemable now</div></div>${redeemBtn}</div>`;
    }).join(''):'<div class="muted">No lending positions.</div>';
    const collateralList=document.getElementById('collateral-list');
    if(collateralList) collateralList.innerHTML=data.collateral.length?data.collateral.map(item=>`<div class="token-row"><div class="token"><div class="coin">${item.token.symbol}</div><div><div class="num">${this.formatTokenAmount(item.amount,item.token.decimals,item.token.symbol)}</div><div class="muted">Deposited</div></div></div><div><div class="num">${this.formatUsdFromDebt(data.risk.collateral_value)}</div><div class="muted">Portfolio value</div></div></div>`).join(''):'<div class="muted">No collateral deposited.</div>';
    const walletList=document.getElementById('wallet-list');
    if(walletList) walletList.innerHTML=data.wallet.length?data.wallet.map(item=>`<div class="token-row"><div class="token"><div class="coin">${item.token.symbol}</div><div><div class="num">${this.formatTokenAmount(item.amount,item.token.decimals,item.token.symbol)}</div><div class="muted">Wallet</div></div></div><div class="num">—</div></div>`).join(''):'<div class="muted">No wallet balances.</div>';
  },

  fillCollateralSelects(collaterals){
    const items=collaterals||[];
    ['deposit-token-select','withdraw-token-select'].forEach(id=>{
      const select=document.getElementById(id);
      if(!select) return;
      const previous=select.value;
      select.innerHTML=items.map(item=>`<option value="${item.id}">${item.symbol}</option>`).join('');
      const keep=previous&&items.some(item=>String(item.id)===String(previous));
      const ethLike=items.find(item=>this.isEthLikeCollateral(item.symbol));
      if(keep) select.value=previous;
      else if(ethLike) select.value=String(ethLike.id);
    });
    this.updateDepositBalance();
  },

  preferDepositedCollateral(selectId='withdraw-token-select'){
    const select=document.getElementById(selectId);
    const deposited=this.portfolio?.collateral?.[0];
    const match=this.market?.collaterals?.find(item=>item.address===deposited?.token.address||item.symbol===deposited?.token.symbol);
    if(select && match) select.value=String(match.id);
    this.updateDepositBalance();
  },

  selectedCollateral(selectId='deposit-token-select'){
    const select=document.getElementById(selectId);
    const id=Number(select?.value);
    return this.market?.collaterals?.find(item=>Number(item.id)===id)||null;
  },

  updateDepositBalance(){
    const walletToken=this.selectedCollateral('deposit-token-select');
    const depositedToken=this.selectedCollateral('withdraw-token-select');
    const walletBalanceEl=document.getElementById('deposit-token-balance');
    const depositedBalanceEl=document.getElementById('withdraw-token-balance');
    const walletItem=this.portfolio?.wallet?.find(entry=>entry.token.address===walletToken?.address||entry.token.symbol===walletToken?.symbol);
    const depositedItem=this.portfolio?.collateral?.find(entry=>entry.token.address===depositedToken?.address||entry.token.symbol===depositedToken?.symbol);
    if(walletBalanceEl) walletBalanceEl.textContent=walletToken?(walletItem?`${ethers.formatUnits(walletItem.amount,walletToken.decimals)} ${walletToken.symbol}`:`0 ${walletToken.symbol}`):'';
    if(depositedBalanceEl) depositedBalanceEl.textContent=depositedToken?(depositedItem?`${ethers.formatUnits(depositedItem.amount,depositedToken.decimals)} ${depositedToken.symbol}`:`0 ${depositedToken.symbol}`):'';
  },

  renderOpenOrders(data){
    const openOrders=document.getElementById('open-orders-list');
    if(!openOrders) return;
    const rows=[
      ...(data.borrow?.items||[]).map(item=>`<div class="order-row"><div><div class="num">Borrow · ${this.maturityLabel(item.maturity)}</div><div class="muted">Open order</div></div><div class="num">${this.formatDebt(item.remaining_face||item.face_amount)}</div><span class="pill orange">Open</span><button class="btn btn-danger-soft" type="button" data-cancel-order="borrow" data-order-id="${item.order_id}">Cancel</button></div>`),
      ...(data.supply?.items||[]).map(item=>`<div class="order-row"><div><div class="num">Lend · ${this.maturityLabel(item.maturity)}</div><div class="muted">Open order</div></div><div class="num">${this.formatDebt(item.remaining_debt_token||item.debt_token_in)}</div><span class="pill orange">Open</span><button class="btn btn-danger-soft" type="button" data-cancel-order="supply" data-order-id="${item.order_id}">Cancel</button></div>`),
    ];
    openOrders.innerHTML=rows.length?rows.join(''):'<div class="muted">No open orders.</div>';
    this.setSectionHidden('my-open-orders', !rows.length);
  },

  toBig(value){
    try{ return BigInt(value||0); }
    catch{ return 0n; }
  },

  ceilDiv(num,den){
    if(den===0n) return 0n;
    return (num+den-1n)/den;
  },

  vaultForMaturity(maturity){
    return this.market?.maturities?.find(item=>Number(item.timestamp)===Number(maturity))?.vault||null;
  },

  async previewDebtShares(maturity,faceAmount){
    const vault=this.vaultForMaturity(maturity);
    if(!vault || !window.AquaWeb3) return this.toBig(faceAmount);
    try{
      return this.toBig(await AquaWeb3.readContract({
        address:vault,
        abi:AquaConfig.AquaABIs.vault,
        functionName:'previewDebtShares',
        args:[faceAmount],
      }));
    }catch{
      return this.toBig(faceAmount);
    }
  },

  async findCompatibleMatch(data){
    const buys=data.buy?.items||[];
    const sells=data.sell?.items||[];
    let best=null;
    for(const borrow of sells){
      for(const supply of buys){
        const face=this.toBig(borrow.face_amount);
        const minOut=this.toBig(borrow.min_debt_token_out);
        let fillFace=this.toBig(borrow.remaining_face||borrow.face_amount);
        const debtIn=this.toBig(supply.debt_token_in);
        const minTerm=this.toBig(supply.min_term_out);
        const remainingDebt=this.toBig(supply.remaining_debt_token||supply.debt_token_in);
        if(face===0n || minOut===0n || fillFace===0n || debtIn===0n || minTerm===0n || remainingDebt===0n) continue;
        let borrowerMin=this.ceilDiv(minOut*fillFace,face);
        if(borrowerMin>remainingDebt){
          fillFace=(remainingDebt*face)/minOut;
          while(fillFace>0n && this.ceilDiv(minOut*fillFace,face)>remainingDebt) fillFace-=1n;
          borrowerMin=fillFace>0n?this.ceilDiv(minOut*fillFace,face):0n;
        }
        if(fillFace===0n || borrowerMin===0n) continue;
        const shares=await this.previewDebtShares(data.maturity,fillFace);
        let fillDebt=remainingDebt;
        let supplierShares=this.ceilDiv(minTerm*fillDebt,debtIn);
        if(shares<supplierShares){
          fillDebt=borrowerMin;
          supplierShares=this.ceilDiv(minTerm*fillDebt,debtIn);
        }
        if(fillDebt<borrowerMin || shares<supplierShares) continue;
        const score=fillFace+fillDebt;
        if(!best || score>best.score){
          best={
            borrowOrderId:borrow.order_id,
            supplyOrderId:supply.order_id,
            faceAmount:fillFace,
            debtTokenAmount:fillDebt,
            borrowerMin,
            supplierShares,
            shares,
            score,
          };
        }
      }
    }
    return best;
  },

  async renderOrderbook(data,showMatch=false){
    const target=document.querySelector(`[data-panel="${data.maturity}"]`);
    if(!target) return;
    const buy=data.buy?.items||[];
    const sell=data.sell?.items||[];
    if(!buy.length&&!sell.length){
      target.innerHTML='<div class="empty-month">No open orders for this maturity.</div>';
      return;
    }
    const amount=v=>this.formatDebt(v,{digits:0});
    const row=(item,type)=>{
      const now=type==='lender'?(item.remaining_debt_token||item.debt_token_in):(item.min_debt_token_out);
      const later=type==='lender'?(item.min_term_out):(item.remaining_face||item.face_amount);
      const rate=Number(now)>0?((Number(later)/Number(now)-1)*100).toFixed(1):'—';
      return `<div class="ladder-row ${type==='lender'?'lender':'borrower'}"><div><span class="side-badge"><span class="side-dot"></span>${type==='lender'?'Lend':'Borrow'}</span><span class="muted">${type==='lender'?'Lend now':'Get now'}</span><br><b>${amount(now)}</b></div><div class="flow-arrow">${type==='lender'?'→':'←'}</div><div><span class="muted">${type==='lender'?'Receive later':'Repay later'}</span><br><b>${amount(later)}</b></div><div class="rate">${rate}%</div></div>`;
    };
    const match=showMatch?await this.findCompatibleMatch(data):null;
    let matchHtml='';
    if(match){
      const rewardParts=[];
      const extraDebt=match.debtTokenAmount-match.borrowerMin;
      const extraShares=match.shares-match.supplierShares;
      if(extraDebt>0n) rewardParts.push(this.formatDebt(extraDebt.toString()));
      if(extraShares>0n) rewardParts.push(`${this.formatDebt(extraShares.toString())} shares`);
      const reward=rewardParts.length?`Reward: ${rewardParts.join(' + ')}`:'Available to execute';
      matchHtml=`<div class="match-zone"><div class="match-title">Match available</div><div class="reward">${reward}</div><button class="btn btn-primary" type="button" style="margin-top:9px;width:100%" data-match-borrow="${match.borrowOrderId}" data-match-supply="${match.supplyOrderId}" data-match-face="${match.faceAmount}" data-match-debt="${match.debtTokenAmount}">Match!</button></div>`;
    }
    target.innerHTML=buy.map(item=>row(item,'lender')).join('')+matchHtml+sell.map(item=>row(item,'borrower')).join('');
  },
};
window.AquaApi=AquaApi;
