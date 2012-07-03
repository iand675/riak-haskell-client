{-# LANGUAGE TemplateHaskell, RecordWildCards, DeriveDataTypeable, OverloadedStrings, GADTs, Rank2Types #-}
module Network.Riak.MapReduce 
  ( Language (..)
  , Input (..)
  , Phase (..)
  , Job (..)
  , MR.MapReduceRequest
  , mapReduce
  ) where

import Data.Aeson
import Data.Aeson.TH
import Data.ByteString.Lazy.Char8 (ByteString)
import Data.Char
import Data.Text (Text)
import Data.Typeable (Typeable)
import qualified Data.Vector as V
import Network.Riak.Types
import qualified Network.Riak.Protocol.MapReduceRequest as MR

type Index = ByteString
type IndexKey = ByteString

data Transform from to where 
  IntToString :: Transform Int Text
  StringToInt :: Transform Text Int
  FloatToString :: Transform Text String
  StringToFloat :: Transform Text Float
  ToUpper :: Transform Text Text
  ToLower :: Transform Text Text
  Tokenize :: Text -> Int -> Transform Text Text
  URLDecode :: Transform Text Text
  (:>) :: Transform a b -> Transform b c -> Transform a c

instance ToJSON (Transform a b) where
  toJSON = toJSON . toJSONArray
  
toJSONArray :: Transform a b -> [Value]
toJSONArray (l :> r) = toJSONArray l ++ toJSONArray r
toJSONArray IntToString = [toJSON ["int_to_string" :: Text]]
toJSONArray StringToInt = [toJSON ["string_to_int" :: Text]]
toJSONArray FloatToString = [toJSON ["float_to_string" :: Text]]
toJSONArray StringToFloat = [toJSON ["string_to_float" :: Text]]
toJSONArray ToUpper = [toJSON ["to_upper" :: Text]]
toJSONArray ToLower = [toJSON ["to_lower" :: Text]]
toJSONArray (Tokenize t i) = [toJSON ("tokenize" :: Text, t, i)]
toJSONArray URLDecode = [toJSON ["urldecode" :: Text]]

data Predicate a where
  GreaterThan :: a -> Predicate a
  LessThan :: a -> Predicate a
  GreaterThanEq :: a -> Predicate a
  LessThanEq :: a -> Predicate a
  Between :: a -> a -> Bool -> Predicate a
  Matches :: Text -> Predicate Text
  NotEqual :: a -> Predicate a
  Equal :: a -> Predicate a
  SetMember :: [a] -> Predicate a
  SimilarTo :: Text -> Int -> Predicate Text
  StartsWith :: Text -> Predicate Text
  EndsWith :: Text -> Predicate Text
  And :: [Predicate a] -> Predicate a
  Or :: [Predicate a] -> Predicate a
  Not :: Predicate a -> Predicate a

instance ToJSON a => ToJSON (Predicate a) where
  toJSON p = case p of
    (GreaterThan x) -> toJSON ("greater_than" :: Text, x)
    (LessThan x) -> toJSON ("less_than" :: Text, x)
    (GreaterThanEq x) -> toJSON ("greater_than_eq" :: Text, x)
    (LessThanEq x) -> toJSON ("less_than_eq" :: Text, x)
    (Between x1 x2 inc) -> toJSON ("between" :: Text, x1, x2, inc)
    (Matches t) -> toJSON ("matches" :: Text, t)
    (NotEqual x) -> toJSON ("neq" :: Text, x)
    (Equal x) -> toJSON ("eq" :: Text, x)
    (SetMember xs) -> toJSON (toJSON ("set_member" :: Text) : map toJSON xs)
    (SimilarTo t i) -> toJSON ("similar_to" :: Text, t, i)
    (StartsWith t) -> toJSON ("starts_with" :: Text, t)
    (EndsWith t) -> toJSON ("ends_with" :: Text, t)
    (And xs) -> toJSON (toJSON ("and" :: Text) : map nest xs)
    (Or xs) -> toJSON (toJSON ("or" :: Text) : map nest xs)
    (Not p) -> toJSON ("not" :: Text, p)
    where nest = toJSON . (:[])

data KeyFilter a = KeyFilter { transforms :: Transform Text a
                             , predicate :: Predicate a }

data Language = Javascript
              | Erlang
              deriving (Eq, Show, Typeable)

instance ToJSON Language where
  toJSON Javascript = toJSON ("javascript" :: Text)
  toJSON Erlang = toJSON ("erlang" :: Text)

data Input = Keys [(Bucket, Key)]
           | KeysWithData [(Bucket, Key, ByteString)]
           | IndexExact { inputBucket :: Bucket, inputIndex :: Index, inputIndexKey :: IndexKey }
           | IndexRange { inputBucket :: Bucket, inputIndex :: Index, inputStart :: IndexKey, inputEnd :: IndexKey }
           | SearchQuery { inputBucket :: Bucket, inputQuery :: ByteString, inputFilter :: Maybe ByteString }
           | FullBucket { inputBucket :: Bucket {-, inputKeyFilter :: Maybe [KeyFilter] -}}
           deriving (Eq, Show, Typeable)

instance ToJSON Input where
  toJSON (Keys bks) = toJSON bks
  toJSON (KeysWithData bkds) = toJSON bkds
  toJSON (IndexExact {..}) = object [ "bucket" .= inputBucket
                                    , "index" .= inputIndex
                                    , "key" .= inputIndexKey
                                    ]
  toJSON (IndexRange {..}) = object [ "bucket" .= inputBucket
                                    , "index" .= inputIndex
                                    , "start" .= inputStart
                                    , "end" .= inputEnd
                                    ]
  toJSON (SearchQuery {..}) = object [ "bucket" .= inputBucket
                                     , "query" .= inputQuery
                                     , "filter" .= inputFilter
                                     ]
  toJSON (FullBucket {..}) = toJSON inputBucket
  
data Phase = MapPhase { phaseLanguage :: Language
                      , phaseSource :: ByteString
                      , phaseKeep :: Maybe Bool }
           | ReducePhase { phaseLanguage :: Language
                         , phaseSource :: ByteString
                         , phaseKeep :: Maybe Bool }
           | LinkPhase { phaseBucket :: Maybe Bucket
                       , phaseTag :: Maybe Tag
                       , phaseKeep :: Maybe Bool }
           deriving (Eq, Show, Typeable)

instance ToJSON Phase where
  toJSON (MapPhase {..}) = object [ "map" .= object [ "language" .= phaseLanguage
                                                    , "source" .= phaseSource
                                                    , "keep" .= phaseKeep ]]
  
  toJSON (ReducePhase {..}) = object [ "reduce" .= object [ "language" .= phaseLanguage
                                                          , "source" .= phaseSource
                                                          , "keep" .= phaseKeep ]]

  toJSON (LinkPhase {..}) = object [ "link" .= object [ "bucket" .= phaseBucket
                                                      , "tag" .= phaseTag
                                                      , "keep" .= phaseKeep
                                                      ]]

data Job = Job { jobInputs :: Input
               , jobQuery :: [Phase]
               }
         deriving (Eq, Show, Typeable)

instance ToJSON Job where
  toJSON (Job {..}) = object [ "inputs" .= jobInputs
                             , "query" .= jobQuery
                             ]

-- | Create a map-reduce request.
mapReduce :: Job -> MR.MapReduceRequest
mapReduce j = MR.MapReduceRequest (encode j) "application/json"
