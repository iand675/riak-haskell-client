{-# LANGUAGE TemplateHaskell, RecordWildCards, DeriveDataTypeable, OverloadedStrings #-}
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
import Network.Riak.Types
import qualified Network.Riak.Protocol.MapReduceRequest as MR

type Index = ByteString
type IndexKey = ByteString

{-
data KeyFilter a = IntToString
                 | StringToInt
                 | FloatToString
                 | StringToFloat
                 | ToUpper
                 | ToLower
                 | Tokenize Text Int
                 | URLDecode
                 | GreaterThan a
                 | LessThan a
                 | GreaterThanEq a
                 | LessThanEq a
                 | Between a a Bool
                 | Matches Text
                 | NotEqual a
                 | Equal a
                 | SetMember [a]
                 | SimilarTo Text a
                 | StartsWith Text
                 | EndsWith Text
                 | And (KeyFilter a) (KeyFilter a)
                 | Or (KeyFilter a) (KeyFilter a)
                 | Not (KeyFilter a)

data PredVal = PredString Text
             | PredNum Int
             | PredBool
-}

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
  
data Phase = Map { phaseLanguage :: Language
                 , phaseSource :: ByteString
                 , phaseKeep :: Maybe Bool }
           | Reduce { phaseLanguage :: Language
                    , phaseSource :: ByteString
                    , phaseKeep :: Maybe Bool }
           | Link { phaseBucket :: Maybe Bucket
                  , phaseTag :: Maybe Tag
                  , phaseKeep :: Maybe Bool }
           deriving (Eq, Show, Typeable)

instance ToJSON Phase where
  toJSON (Map {..}) = object [ "map" .= object [ "language" .= phaseLanguage
                                               , "source" .= phaseSource
                                               , "keep" .= phaseKeep ]]
  
  toJSON (Reduce {..}) = object [ "reduce" .= object [ "language" .= phaseLanguage
                                                     , "source" .= phaseSource
                                                     , "keep" .= phaseKeep ]]

  toJSON (Link {..}) = object [ "link" .= object [ "bucket" .= phaseBucket
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
