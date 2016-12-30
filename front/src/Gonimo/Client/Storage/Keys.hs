{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
module Gonimo.Client.Storage.Keys where

import Gonimo.SocketAPI.Types as API
import Data.Aeson (FromJSON, ToJSON, toEncoding, genericToEncoding, defaultOptions)
import GHC.Generics (Generic)

data Key a = KeyAuthData
           | CurrentFamily
           | VideoEnabled

deriving instance Generic (Key a)

-- | Needed because deriving clause did not work for GADT, although it should according to documentation
keyAuthData :: Key API.AuthData
keyAuthData = KeyAuthData

instance FromJSON (Key a)
instance ToJSON (Key a) where
  toEncoding = genericToEncoding defaultOptions



-- currentFamily :: Key (Gonimo.Key Family)
-- currentFamily = CurrentFamily

-- videoEnabled :: Key Boolean
-- videoEnabled = VideoEnabled