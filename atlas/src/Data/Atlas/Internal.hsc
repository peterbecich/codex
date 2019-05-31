{-# language BangPatterns #-}
{-# language ForeignFunctionInterface #-}
{-# language LambdaCase #-}
{-# language ViewPatterns #-}
{-# language DeriveDataTypeable #-}
{-# language RecordWildCards #-}
{-# language ScopedTypeVariables #-}
{-# language StandaloneDeriving #-}
{-# language UndecidableInstances #-}
{-# language MultiParamTypeClasses #-}
{-# language FunctionalDependencies #-}
{-# language TemplateHaskell #-}
{-# language MultiWayIf #-}
{-# language FlexibleInstances #-}
-- |
-- Copyright :  (c) 2019 Edward Kmett
-- License   :  BSD-2-Clause OR Apache-2.0
-- Maintainer:  Edward Kmett <ekmett@gmail.com>
-- Stability :  experimental
-- Portability: non-portable
--
-- Details of the implementation.
--
-- The contents of this module do not fall under the PVP. Use at your own risk.
module Data.Atlas.Internal
( Atlas(..), Coord, Rect, Node
, withAtlas
, heuristicId, Heuristic(..)
, stbrp_init_target
, stbrp_setup_allow_out_of_mem
, stbrp_pack_rects
, stbrp_setup_heuristic
, sizeOfAtlas
, sizeOfNode
, sizeOfRect
, Pt(..), HasPt(..)
, peekWH, peekXY
, Box(..), HasBox(..)
, pokePts
, boxMaybe
) where

import Control.Lens
import Data.Coerce
import Data.Data (Data)
import Data.Default
import Data.HKD
import Foreign.C.Types
import Foreign.ForeignPtr
import Foreign.Ptr
import Foreign.Storable
import GHC.Arr

#ifndef HLINT
#include "stb_rect_pack.h"
#endif

newtype Atlas s = Atlas (ForeignPtr (Atlas s))
  deriving (Eq,Ord,Show,Data)

withAtlas :: Atlas s -> (Ptr (Atlas s) -> IO r) -> IO r
withAtlas = withForeignPtr . coerce

sizeOfAtlas :: Int
sizeOfAtlas = #size stbrp_context

sizeOfNode :: Int
sizeOfNode = #size stbrp_node

sizeOfRect :: Int
sizeOfRect = #size stbrp_rect

type Coord = CUShort -- Word16

data Rect
data Node

data Heuristic
  = BL -- bottom-left sort-height
  | BF -- best first sort-height
  deriving (Eq,Ord,Show,Read,Enum,Ix,Bounded)

instance Default Heuristic where
  def = BL

heuristicId :: Heuristic -> CInt
heuristicId BL = #const STBRP_HEURISTIC_Skyline_BL_sortHeight
heuristicId BF = #const STBRP_HEURISTIC_Skyline_BF_sortHeight

-- ffi bits
foreign import ccall "stbrp_rect_pack.h stbrp_init_target " stbrp_init_target :: Ptr (Atlas s) -> CInt -> CInt -> Ptr Node -> CInt -> IO ()
foreign import ccall "stbrp_rect_pack.h stbrp_setup_allow_out_of_mem" stbrp_setup_allow_out_of_mem :: Ptr (Atlas s) -> CInt -> IO ()
foreign import ccall "stbrp_rect_pack.h stbrp_pack_rects" stbrp_pack_rects :: Ptr (Atlas s) -> Ptr Rect -> CInt -> IO CInt
foreign import ccall "stbrp_rect_pack.h stbrp_setup_heuristic" stbrp_setup_heuristic :: Ptr (Atlas s) -> CInt -> IO ()

-- | Use and cast back and forth to ints instead for more natural API?
data Pt = Pt
  { _ptX, _ptY :: {-# unpack #-} !Int
  } deriving (Eq,Ord,Show,Read)

makeClassy ''Pt

instance Num Pt where
  Pt a b + Pt c d = Pt (a + c) (b + d)
  Pt a b - Pt c d = Pt (a - c) (b - d)
  Pt a b * Pt c d = Pt (a * c) (b * d)
  abs (Pt a b) = Pt (abs a) (abs b)
  signum (Pt a b) = Pt (signum a) (signum b)
  negate (Pt a b) = Pt (negate a) (negate b)
  fromInteger n = Pt (fromInteger n) (fromInteger n)

peekWH :: Ptr Rect -> IO Pt
peekWH p = (\(w :: Coord) (h :: Coord) -> Pt (fromIntegral w) (fromIntegral h))
  <$> (#peek stbrp_rect, w) p
  <*> (#peek stbrp_rect, h) p

peekXY :: Ptr Rect -> IO Pt
peekXY p = (\(w :: Coord) (h :: Coord) -> Pt (fromIntegral w) (fromIntegral h))
  <$> (#peek stbrp_rect, x) p
  <*> (#peek stbrp_rect, y) p

-- hkd rectangles
data Box f = Box
  { _boxPosition :: !(f Pt)
  , _boxSize :: {-# unpack #-} !Pt
  }

makeClassy ''Box

instance FFunctor Box where
  ffmap f (Box g h) = Box (f g) h

instance FFoldable Box where
  ffoldMap f (Box g _) = f g
  flengthAcc acc _ = acc + 1

instance FTraversable Box where
  ftraverse f (Box g h) = (\g' -> Box g' h) <$> f g

deriving instance Eq (f Pt) => Eq (Box f)
deriving instance Ord (f Pt) => Ord (Box f)
deriving instance Read (f Pt) => Read (Box f)
deriving instance Show (f Pt) => Show (Box f)

pokePts :: (a -> Box t) -> Ptr Rect -> [a] -> IO ()
pokePts f ptr vals0 = go vals0 0 where
  go ((f -> Box _ (Pt w h)):vals) !i = do
    let p = plusPtr ptr (i*sizeOfRect)
    (#poke stbrp_rect, w) p (fromIntegral w :: Coord)
    (#poke stbrp_rect, h) p (fromIntegral h :: Coord)
    go vals (i + 1)
  go []  _ = pure ()
{-# inline pokePts #-}

boxMaybe :: Ptr Rect -> IO (Maybe Pt)
boxMaybe p = (#peek stbrp_rect, was_packed) p >>= \case
  (0 :: CInt) -> pure Nothing
  _ -> Just <$> peekXY p
