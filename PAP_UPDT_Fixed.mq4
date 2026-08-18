//+------------------------------------------------------------------+
//|                                              PAP_UPDT_Fixed.mq4  |
//|                                  Smart Hedging & Direction Lock  |
//|                                          Revised Architecture    |
//+------------------------------------------------------------------+
#property copyright "Smart Hedging 20-1 (Direction Confidence System)"
#property link      ""
#property version   "2.00"
#property strict

//--- Input Parameters
input group "=== Risk Management ==="
input double LotSize = 0.01;                // Initial Lot Size
input int    MaxOrdersPerSide = 5;          // Max Orders per Side (Buy/Sell)
input double MartingaleMultiplier = 1.5;    // Martingale Multiplier
input double MaxDailyLossUSD = 100.0;       // Max Daily Loss in USD

input group "=== Dynamic Grid & ATR ==="
input bool   UseDynamicGrid = true;         // Enable Dynamic Grid based on ATR
input int    ATRPeriod = 14;                // ATR Period for Volatility
input double GridMultiplier = 1.5;          // Multiplier for ATR to set Grid Distance
input int    FixedGridPoints = 200;         // Fixed Grid Points (if Dynamic is false)

input group "=== Signal & Confidence ==="
input int    MinConfidenceBase = 60;        // Minimum Confidence to Open New Trade (%)
input int    MinConfidenceFloor = 40;       // Confidence Floor to Hold/Manage (%)
input int    BlindEntryEveryMinutes = 0;    // Minutes between Blind Entries (0 = Disabled)

input group "=== Hedge & Lock Module ==="
input bool   EnableAutoHedgeLock = true;    // Enable Auto Hedge Lock when Signal is Neutral
input double HedgeLockThreshold = 5.0;      // Net Exposure Threshold to Trigger Lock (in Lots * 100)

input group "=== Extraction (Take Profit) ==="
input int    MinExtractionDistancePoints = 150; // Min Distance for Extraction TP
input double ExtractionProfitUSD = 10.0;    // Target Profit for Extraction

input group "=== Time Filter ==="
input bool   UseTimeFilter = false;         // Enable Time Filter
input int    StartHour = 0;                 // Trading Start Hour
input int    EndHour = 23;                  // Trading End Hour

input group "=== Magic Number ==="
input int    MagicNumber = 888888;          // Unique Magic Number

//--- Global Variables
int g_magicNumber = 0;
double g_atrValue = 0;
datetime g_lastBlindEntryTime = 0;
datetime g_lastSignalTime = 0;
double g_currentConfidence = 0;
int g_signalState = 0; // 1=Buy, -1=Sell, 0=Neutral/Lock

// Handles for Indicators
int handleATR = INVALID_HANDLE;
int handleRSI = INVALID_HANDLE;
int handleMACD_Main = INVALID_HANDLE;
int handleMACD_Signal = INVALID_HANDLE;
int handleBB_Upper = INVALID_HANDLE;
int handleBB_Lower = INVALID_HANDLE;
int handleStoch_Main = INVALID_HANDLE;
int handleStoch_Signal = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   g_magicNumber = MagicNumber;
   
   // Initialize Indicator Handles
   handleATR = iATR(_Symbol, _Period, ATRPeriod);
   handleRSI = iRSI(_Symbol, _Period, 14, PRICE_CLOSE);
   handleMACD_Main = iMACD(_Symbol, _Period, 12, 26, 9, PRICE_CLOSE);
   // For BB and Stoch, we need buffers or simplified logic for this example
   // Simplified: Using standard library or direct calculation if needed, 
   // but for MQL4 simplicity in one file, we will simulate logic or use iBands/iStochastic
   
   if(handleATR == INVALID_HANDLE || handleRSI == INVALID_HANDLE || handleMACD_Main == INVALID_HANDLE)
   {
      Print("Error initializing indicators.");
      return(INIT_FAILED);
   }

   Print("Expert Advisor Initialized Successfully with New Logic.");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleATR);
   IndicatorRelease(handleRSI);
   IndicatorRelease(handleMACD_Main);
   // Release other handles if created
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. Check Time Filter
   if(UseTimeFilter)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.hour < StartHour || dt.hour >= EndHour)
         return;
   }

   // 2. Update Market Data & Indicators
   double atrBuffer[], rsiBuffer[], macdMainBuffer[], macdSigBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   ArraySetAsSeries(rsiBuffer, true);
   ArraySetAsSeries(macdMainBuffer, true);
   ArraySetAsSeries(macdSigBuffer, true);

   if(CopyBuffer(handleATR, 0, 0, 3, atrBuffer) < 3) return;
   if(CopyBuffer(handleRSI, 0, 0, 3, rsiBuffer) < 3) return;
   if(CopyBuffer(handleMACD_Main, 0, 0, 3, macdMainBuffer) < 3) return;
   if(CopyBuffer(handleMACD_Main, 1, 0, 3, macdSigBuffer) < 3) return; // Signal line is buffer 1

   g_atrValue = atrBuffer[0];
   
   // 3. Calculate Direction Confidence Score (0-100)
   int score = CalculateConfidenceScore(rsiBuffer[0], macdMainBuffer[0], macdSigBuffer[0], atrBuffer[0]);
   g_currentConfidence = (double)score;

   // Determine Signal State
   if(score >= MinConfidenceBase)
      g_signalState = 1; // Buy Signal
   else if(score <= (100 - MinConfidenceBase))
      g_signalState = -1; // Sell Signal
   else
      g_signalState = 0; // Neutral / Ambiguous

   // 4. Manage Existing Positions (Extraction & Hedge Lock)
   ManagePositions();

   // 5. Execute Entry Logic
   ExecuteEntryLogic();
}

//+------------------------------------------------------------------+
//| Calculate Confidence Score                                         |
//+------------------------------------------------------------------+
int CalculateConfidenceScore(double rsi, double macdMain, double macdSig, double atr)
{
   int score = 50; // Base neutral

   // RSI Contribution (Max 30 points)
   if(rsi > 70) score += 30;
   else if(rsi > 50) score += 15;
   else if(rsi < 30) score -= 30;
   else if(rsi < 50) score -= 15;

   // MACD Contribution (Max 40 points)
   if(macdMain > macdSig && macdMain > 0) score += 40;
   else if(macdMain > macdSig) score += 20;
   else if(macdMain < macdSig && macdMain < 0) score -= 40;
   else if(macdMain < macdSig) score -= 20;

   // Trend Filter (Simple MA check could be added here, simulating with Price vs Open)
   // Adding volatility adjustment: High volatility might reduce confidence slightly if against trend
   // For now, keeping it simple based on provided indicators.

   // Clamp score between 0 and 100
   if(score > 100) score = 100;
   if(score < 0) score = 0;

   return score;
}

//+------------------------------------------------------------------+
//| Manage Positions (Extraction & Hedge Lock)                         |
//+------------------------------------------------------------------+
void ManagePositions()
{
   double totalBuyLots = 0;
   double totalSellLots = 0;
   double totalProfit = 0;
   int buyCount = 0;
   int sellCount = 0;
   
   double highestBuyPrice = 0;
   double lowestSellPrice = 0;

   // Scan all orders for this EA
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == _Symbol && OrderMagicNumber() == g_magicNumber)
         {
            if(OrderType() == OP_BUY)
            {
               totalBuyLots += OrderLots();
               buyCount++;
               totalProfit += OrderProfit() + OrderSwap() + OrderCommission();
               if(highestBuyPrice == 0 || OrderOpenPrice() > highestBuyPrice)
                  highestBuyPrice = OrderOpenPrice();
            }
            else if(OrderType() == OP_SELL)
            {
               totalSellLots += OrderLots();
               sellCount++;
               totalProfit += OrderProfit() + OrderSwap() + OrderCommission();
               if(lowestSellPrice == 0 || OrderOpenPrice() < lowestSellPrice)
                  lowestSellPrice = OrderOpenPrice();
            }
         }
      }
   }

   // --- Hedge Lock Module ---
   if(EnableAutoHedgeLock && g_signalState == 0)
   {
      double netExposure = totalBuyLots - totalSellLots;
      
      // If significant imbalance exists and signal is neutral, lock it
      if(MathAbs(netExposure) > (HedgeLockThreshold / 100.0))
      {
         double lotToOpen = MathAbs(netExposure);
         // Normalize lot size
         lotToOpen = NormalizeLot(lotToOpen);
         
         if(lotToOpen >= MarketInfo(_Symbol, MODE_MINLOT))
         {
            if(netExposure > 0) // More Buys, need to Sell to lock
            {
               OpenOrder(OP_SELL, lotToOpen, "HedgeLock");
            }
            else // More Sells, need to Buy to lock
            {
               OpenOrder(OP_BUY, lotToOpen, "HedgeLock");
            }
            Print("Hedge Lock Activated: Opened ", lotToOpen, " lots to neutralize exposure.");
         }
      }
   }

   // --- Extraction Module ---
   // Close positions if profit target reached or specific distance criteria met
   if(totalProfit >= ExtractionProfitUSD)
   {
      // Simple extraction: Close all if target met (Can be refined to partial close)
      CloseAllOrders("ExtractionTP");
   }
}

//+------------------------------------------------------------------+
//| Execute Entry Logic                                                |
//+------------------------------------------------------------------+
void ExecuteEntryLogic()
{
   // Count current orders
   int buyCount = 0;
   int sellCount = 0;
   double lastBuyPrice = 0;
   double lastSellPrice = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == _Symbol && OrderMagicNumber() == g_magicNumber)
         {
            if(OrderType() == OP_BUY)
            {
               buyCount++;
               if(lastBuyPrice == 0 || OrderOpenPrice() > lastBuyPrice) // Assuming latest entry is highest price in grid? No, usually latest is closest to price.
               // Let's find the most recent order by time if needed, but for grid, we care about price levels.
               // Simplified: Just count for limits.
            }
            else if(OrderType() == OP_SELL)
            {
               sellCount++;
            }
         }
      }
   }

   // Blind Entry Logic (if enabled)
   if(BlindEntryEveryMinutes > 0)
   {
      if(TimeCurrent() - g_lastBlindEntryTime >= BlindEntryEveryMinutes * 60)
      {
         // Open a small blind position based on minor trend or just alternate
         // For safety, only if no heavy exposure
         if(buyCount == 0 && sellCount == 0)
         {
            OpenOrder(OP_BUY, LotSize, "BlindEntry");
            g_lastBlindEntryTime = TimeCurrent();
            return;
         }
      }
   }

   // Signal Based Entry
   if(g_signalState == 1 && buyCount < MaxOrdersPerSide)
   {
      // Check if we should add a buy order
      // Dynamic Grid Calculation
      double gridDistance = GetGridDistance();
      double currentPrice = MarketInfo(_Symbol, MODE_ASK);
      
      bool canEnter = true;
      if(buyCount > 0)
      {
         // Find last buy price
         double maxBuyPrice = 0;
         for(int i = OrdersTotal() - 1; i >= 0; i--)
         {
            if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && OrderSymbol() == _Symbol && OrderMagicNumber() == g_magicNumber && OrderType() == OP_BUY)
            {
               if(OrderOpenPrice() > maxBuyPrice) maxBuyPrice = OrderOpenPrice();
            }
         }
         if(currentPrice < maxBuyPrice + gridDistance * Point)
            canEnter = false; // Too close to last order
      }

      if(canEnter && g_currentConfidence >= MinConfidenceBase)
      {
         double lot = CalculateLotSize(buyCount);
         OpenOrder(OP_BUY, lot, "SignalBuy");
      }
   }
   else if(g_signalState == -1 && sellCount < MaxOrdersPerSide)
   {
      // Check if we should add a sell order
      double gridDistance = GetGridDistance();
      double currentPrice = MarketInfo(_Symbol, MODE_BID);
      
      bool canEnter = true;
      if(sellCount > 0)
      {
         double minSellPrice = 0;
         for(int i = OrdersTotal() - 1; i >= 0; i--)
         {
            if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && OrderSymbol() == _Symbol && OrderMagicNumber() == g_magicNumber && OrderType() == OP_SELL)
            {
               if(minSellPrice == 0 || OrderOpenPrice() < minSellPrice) minSellPrice = OrderOpenPrice();
            }
         }
         if(currentPrice > minSellPrice - gridDistance * Point)
            canEnter = false;
      }

      if(canEnter && g_currentConfidence <= (100 - MinConfidenceBase))
      {
         double lot = CalculateLotSize(sellCount);
         OpenOrder(OP_SELL, lot, "SignalSell");
      }
   }
}

//+------------------------------------------------------------------+
//| Helper: Get Dynamic Grid Distance                                  |
//+------------------------------------------------------------------+
double GetGridDistance()
{
   if(UseDynamicGrid && g_atrValue > 0)
   {
      return g_atrValue * GridMultiplier;
   }
   return FixedGridPoints;
}

//+------------------------------------------------------------------+
//| Helper: Calculate Lot Size (Martingale)                            |
//+------------------------------------------------------------------+
double CalculateLotSize(int orderCount)
{
   double lot = LotSize * MathPow(MartingaleMultiplier, orderCount);
   return NormalizeLot(lot);
}

//+------------------------------------------------------------------+
//| Helper: Normalize Lot Size                                         |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot = MarketInfo(_Symbol, MODE_MINLOT);
   double maxLot = MarketInfo(_Symbol, MODE_MAXLOT);
   double step = MarketInfo(_Symbol, MODE_LOTSTEP);
   
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   
   lot = MathFloor(lot / step) * step;
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Helper: Open Order                                                 |
//+------------------------------------------------------------------+
bool OpenOrder(int type, double lots, string comment)
{
   double price = (type == OP_BUY) ? MarketInfo(_Symbol, MODE_ASK) : MarketInfo(_Symbol, MODE_BID);
   double sl = 0;
   double tp = 0;
   
   // Optional: Set SL/TP based on ATR or fixed points
   // For now, relying on global management (Hedge/Extraction)
   
   int ticket = OrderSend(_Symbol, type, lots, price, 3, sl, tp, comment, g_magicNumber, 0, (type == OP_BUY) ? clrBlue : clrRed);
   
   if(ticket < 0)
   {
      Print("OrderSend Error: ", GetLastError());
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Helper: Close All Orders                                           |
//+------------------------------------------------------------------+
void CloseAllOrders(string reason)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
      {
         if(OrderSymbol() == _Symbol && OrderMagicNumber() == g_magicNumber)
         {
            double closePrice = (OrderType() == OP_BUY) ? MarketInfo(_Symbol, MODE_BID) : MarketInfo(_Symbol, MODE_ASK);
            OrderClose(OrderTicket(), OrderLots(), closePrice, 3, clrNONE);
         }
      }
   }
}
//+------------------------------------------------------------------+
