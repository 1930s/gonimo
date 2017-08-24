{- Stolen and modified from reflex-dom, thanks!

Copyright (c) 2015, Obsidian Systems LLC
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE JavaScriptFFI #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
#ifdef USE_TEMPLATE_HASKELL
{-# LANGUAGE TemplateHaskell #-}
#endif
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Gonimo.Client.Reflex.Dom.WebSocket where

import Prelude hiding (all, concat, concatMap, div, mapM, mapM_, sequence, span)

import Reflex.Class
import Reflex.Dom.Class
import Gonimo.Client.Reflex.Dom.WebSocket.Foreign
import Reflex.PerformEvent.Class
import Reflex.PostBuild.Class
import Reflex.TriggerEvent.Class

import Control.Concurrent
import Control.Exception (SomeException)
import Control.Lens
import Control.Monad hiding (forM, forM_, mapM, mapM_, sequence)
import Control.Monad.IO.Class
import Control.Monad.State
import Data.ByteString (ByteString)
import Data.Default
import Data.IORef
import Data.Maybe (isJust)
import Data.Text
import GHCJS.DOM.Types (runJSM, askJSM, MonadJSM, liftJSM, JSM)
import qualified Language.Javascript.JSaddle.Monad as JS (catch)

import Gonimo.Client.Util


data CloseParams
  = CloseParams {
                  -- | Parameter for the JS close method.
                  -- See: https://developer.mozilla.org/en-US/docs/Web/API/WebSocket#close()
                  _closeCode :: Word
                  -- | Parameter for the JS close method.
                  -- See: https://developer.mozilla.org/en-US/docs/Web/API/WebSocket#close()
                , _closeReason :: Text
                }

data Config t
   = Config { _config_send :: Event t [Text]
            , _config_close :: Event t CloseParams
            , _config_reconnect :: Bool
              -- | Timeout in seconds we wait for the JavaScript WebSocket connection
              -- to send it's close event, before we disconnect all event handlers and trigger
              -- '_webSocket_close' ourselves. Pass 'Nothing' if you want to
              -- wait indefinitely for the JS implementation.
            , _config_closeTimeout :: Maybe Word
            }

data WebSocket t
   = WebSocket { _receive :: Event t Text
               , _open :: Event t ()
               -- | error event does not carry any data and is always
               -- followed by termination of the connection
               -- for details see the close event
               , _error :: Event t ()
               , _close :: Event t ( Bool -- ^ wasClean
                                   , CloseParams
                                   )
               , _cleanup :: Dynamic t (JS.JSM ())
               }


data Environment t
  = Environment { _config :: WebSocketConfig t
                , _webSocket :: WebSocket t
                }

makeLenses ''Config
makeLenses ''WebSocket
makeLenses ''Environment


instance Default CloseParams where
  def = CloseParams { _closeCode = 1000
                    , _closeReason = T.empty
                    }


instance Reflex t => Default (WebSocketconfig t a) where
  def = WebSocketconfig { _webSocketConfig_send = never
                        , _webSocketConfig_close = never
                        , _webSocketConfig_reconnect = True
                        }


-- Differences from stock reflex-dom websocket:
--  - no queue, if connection is not ready - simply drop messages
webSocket :: (MonadJSM m, MonadJSM (Performable m), HasJSContext m, PerformEvent t m, TriggerEvent t m, PostBuild t m) => Text -> Config t -> m (WebSocket t)
webSocket url config = do
    forceRenew <- delay (config^.config_close) (config^.config_close)

    (jsCloseEvent, triggerJSClose) <- newTriggerEvent

    releaseOnClose <- on ws WS.closeEvent $ do
      e <- ask
      wasClean <- getWasClean e
      code <- getCode e
      reason <- getReason e
      liftJSM $ triggerJSClose (wasClean, CloseParams code reason)

    -- fromJS () catches any exception and logs it to the console ...
    performEvent_ $ fromJS () . uncurry JS.sendString <$> attach (current ws) (config^.config_send)

    -- User exposed close event:
    let close' = leftmost [ (False, ) <$> forceRenew
                          , jsCloseEvent
                          ]
    let makeNew = snd <$> close
    ws <- provideWebSocket makeNew

    let result = WebSocket { _close = close'
                          , _cleanup = do
                              releaseOnClose
                          }
    pure result
  where
    onFailedSend :: JS.JSException -> JSM ()
    onFailedSend (JS.JSException e) = do
      T.putStrLn $ showJSException e
      

-- | Provide a websocket and create new one upon request,
-- cleaning up the old one. If the connection needs to be closed the provided code and reason are used.
provideWebSocket :: MonadReader (Environment t) m => Event t CloseParams -> m (Dynamic t WS.WebSocket)
provideWebSocket makeNew = mdo
    wsInit <- newWebSocket url []
    cleanup' <- view (webSocket . cleanup)

    let makeNew' = pushAlways (\closeParams -> do
                                  ws <- sample $ current conn
                                  pure (ws, closeParams)
                              ) makeNew

    newWs <- performEvent $ renew cleanup' <$> makeNew'
    conn <- holdDyn wsInit newWS
    pure conn
  where
    renew cleanup' (ws, ps) = do
      state <- WS.getReadyState ws
      unless (state == WS.CLOSING || state == WS.CLOSED)
        $ WS.close ws (ps^.closeCode) (ps^.closeReason)
      cleanup'
      newWebSocket url []


webSocket' :: forall m t a b. (MonadJSM m, MonadJSM (Performable m), HasJSContext m, PerformEvent t m, TriggerEvent t m, PostBuild t m, IsWebSocketMessage a) => Text -> WebSocketConfig t a -> (Either ByteString JSVal -> JSM b) -> m (RawWebSocket t b)
webSocket' url config onRawMessage = do
  wv <- fmap unJSContextSingleton askJSContext
  (eRecv, onMessage) <- newTriggerEvent
  currentSocketRef <- liftIO $ newIORef Nothing
  (eOpen, triggerEOpen) <- newTriggerEvent
  (eError, triggerEError) <- newTriggerEvent
  (eClose, triggerEClose) <- newTriggerEvent
  let onOpen = do
        liftIO $ putStrLn "Opening ..."
        triggerEOpen ()
      onError = triggerEError ()
      onClose args = do
        liftIO $ putStrLn "Closing ..."
        liftIO $ triggerEClose args
        mws <- liftIO $ readIORef currentSocketRef
        case mws of
          Nothing -> liftIO $ putStrLn "Closing non existing websocket?"
          Just ws -> releaseHandlers ws -- Manually release handlers to prevent opened gonimo in another tab error - hope that helps!
        liftIO $ writeIORef currentSocketRef Nothing
        when (_webSocketConfig_reconnect config) $ do
          liftIO $ threadDelay 2000000
          start

      sendPayload :: forall m1. (MonadJSM m1, MonadIO m1) => a -> m1 ()
      sendPayload payload = do
        mws <- liftIO $ readIORef currentSocketRef
        case mws of
          Nothing -> liftIO $ putStrLn "Tried to send data but there is no open connection!"
          Just ws -> do
            readyState <- liftJSM $ webSocketGetReadyState ws
            if readyState == 1
            then liftJSM $ webSocketSend ws payload `JS.catch` (\(_ :: SomeException) -> liftIO $ putStrLn "Exception when sending!")
            else liftIO $ putStrLn "Tried to send data but connection is not ready!"

      start = do
        ws <- newWebSocket wv url (onRawMessage >=> liftIO . onMessage) (liftIO onOpen) (liftIO onError) onClose
        liftIO $ writeIORef currentSocketRef $ Just ws
        return ()

  performEvent_ . (liftJSM start <$) =<< getPostBuild
  performEvent_ $ ffor (_webSocketConfig_send config) $ mapM_ sendPayload
  performEvent_ $ ffor (_webSocketConfig_close config) $ \(code,reason) -> liftJSM $ do
    mws <- liftIO $ readIORef currentSocketRef
    case mws of
      Nothing -> return ()
      Just ws -> do
        closeWebSocket ws (fromIntegral code) reason `JS.catch` (\(e :: SomeException) -> do
                                                                             liftIO $ putStrLn "Exception during close: "
                                                                             liftIO $ print e
                                                                             -- onClose (False, 1000, "Exception during close!")
                                                                         )

  return $ RawWebSocket eRecv eOpen eError eClose

-- #ifdef USE_TEMPLATE_HASKELL
-- makeLensesWith (lensRules & simpleLenses .~ True) ''WebSocketConfig
-- #else

-- webSocketConfig_send :: Lens' (WebSocketConfig t a) (Event t [a])
-- webSocketConfig_send f (WebSocketConfig x1 x2 x3) = (\y -> WebSocketConfig y x2 x3) <$> f x1
-- {-# INLINE webSocketConfig_send #-}

-- webSocketConfig_close :: Lens' (WebSocketConfig t a) (Event t (Word, Text))
-- webSocketConfig_close f (WebSocketConfig x1 x2 x3) = (\y -> WebSocketConfig x1 y x3) <$> f x2
-- {-# INLINE webSocketConfig_close #-}

-- webSocketConfig_reconnect :: Lens' (WebSocketConfig t a) Bool
-- webSocketConfig_reconnect f (WebSocketConfig x1 x2 x3) = (\y -> WebSocketConfig x1 x2 y) <$> f x3
-- {-# INLINE webSocketConfig_reconnect #-}

-- #endif
