{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeOperators #-}

module Database.Influx.API
    ( ping
    , queryRaw
    , getQueryRaw
    , postQueryRaw
    , postQuery
    , FromInfluxValue(..)
    , FromInfluxPoint(..)
    , Cons(..)
    , getQuery
    , serializeInfluxData
    , write
    ) where

import Database.Influx.Types
      
import Control.Arrow (second)
import Control.Monad (void)
import Data.Either (lefts, rights)
import Data.Maybe (catMaybes, mapMaybe)
import Data.Monoid ((<>))
import Data.Text (Text)
import Network.HTTP.Client.Conduit
import Network.HTTP.Simple
import qualified Data.Aeson.Types as A
import qualified Data.ByteString as B
import qualified Data.HVect as HV
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Scientific as S
import qualified Data.Vector as V
    
credsToQueryString :: Credentials -> [(B.ByteString, Maybe B.ByteString)]
credsToQueryString creds =
    fmap (second Just) $
    [ ("u", T.encodeUtf8 (credsUser creds))
    , ("p", T.encodeUtf8 (credsPassword creds))
    ]

epochToBytestring :: EpochPrecision -> B.ByteString
epochToBytestring epoch =
    case epoch of
      Hours -> "h"
      Minutes -> "m"
      Seconds -> "s"
      Milliseconds -> "ms"
      Microseconds -> "us"
      Nanoseconds -> "ns"

queryParamsToQueryString :: QueryParams -> [(B.ByteString, Maybe B.ByteString)]
queryParamsToQueryString opts =
    fmap (second Just) $
    catMaybes
    [ (,) "chunk_size" . T.encodeUtf8 . T.pack . show <$> qp_chunkSize opts
    , (,) "epoch" . epochToBytestring <$> qp_epoch opts
    , (,) "rp" . T.encodeUtf8 <$> qp_retentionPolicy opts
    , (,) "db" . T.encodeUtf8 <$> qp_database opts
    ]

urlAppend :: String -> String -> String
urlAppend base path = base' ++ "/" ++ path'
  where base' = if last base == '/' then init base else base
        path' = if head path == '/' then tail path else path

ping :: Config -> IO (Maybe InfluxVersion)
ping config =
    do request <- setRequestMethod "HEAD" <$> parseUrl (urlAppend (configServer config) "/ping")
       response <- httpLBS request
       let version = getResponseHeader "X-Influxdb-Version" response
       return $
           if null version || getResponseStatusCode response /= 204
             then Nothing
             else Just . InfluxVersion . T.decodeUtf8 $ head version

queryRaw ::
       B.ByteString -- ^ HTTP method
    -> Config
    -> QueryParams
    -> Query
    -> IO [InfluxResult]
queryRaw method config opts query =
    do let url = configServer config `urlAppend` "/query"
           queryString =
             maybe [] credsToQueryString (configCreds config) ++
             queryParamsToQueryString opts ++
             [ ("q", Just (T.encodeUtf8 (unQuery query))) ]
       baseReq <- parseUrl url
       let req =
             setRequestMethod method $
             maybe id setRequestManager (configManager config) $
             setRequestQueryString queryString baseReq
       res <- httpJSONEither req
       case getResponseBody res of
         Left err -> fail $ "JSON decoding failed: " ++ show err
         Right val -> pure (unInfluxResults val)

getQueryRaw :: Config -> QueryParams -> Query -> IO [InfluxResult]
getQueryRaw = queryRaw "GET"

postQueryRaw :: Config -> QueryParams -> Query -> IO [InfluxResult]
postQueryRaw = queryRaw "POST"

postQuery :: Config -> Maybe DatabaseName -> Query -> IO ()
postQuery config mDatabase query =
    let params = defaultQueryParams { qp_database = mDatabase }
    in void (postQueryRaw config params query)

type Parser = A.Parser

class FromInfluxValue a where
    parseInfluxValue :: Value -> Parser a

instance FromInfluxValue Value where
    parseInfluxValue = pure

instance FromInfluxValue Bool where
    parseInfluxValue val =
        case val of
          Bool b -> pure b
          _ -> fail "expected a bool"

instance FromInfluxValue Text where
    parseInfluxValue val =
        case val of
          String s -> pure s
          _ -> fail "expected a string"

instance FromInfluxValue String where
    parseInfluxValue val =
        case val of
          String s -> pure (T.unpack s)
          _ -> fail "expected a string"

instance FromInfluxValue Integer where
    parseInfluxValue val =
        case val of
          Number s ->
              case S.floatingOrInteger s :: Either Double Integer of
                Left _ -> fail "expected an integer, but got a double"
                Right i -> pure i
          Integer i -> pure i
          _ -> fail "expected an integer"

instance FromInfluxValue Int where
    parseInfluxValue val =
        case val of
          Number s ->
              case S.toBoundedInteger s of
                Nothing -> fail "expected an int, but got a double or an out-of-range integer"
                Just i -> pure i
          Integer i ->
              let intMinBound = toInteger (minBound :: Int)
                  intMaxBound = toInteger (maxBound :: Int)
              in if intMinBound <= i && i <= intMaxBound
                   then pure (fromInteger i)
                   else fail "expected an int, but got an out-of-range integer"
          _ -> fail "expected an integer"

instance FromInfluxValue a => FromInfluxValue (Maybe a) where
    parseInfluxValue val =
        case val of
          Null -> pure Nothing
          _ -> Just <$> parseInfluxValue val

{-
instance FromInfluxValue Time.UTCTime where
    parseInfluxValue val =
        case val of
          String s ->
              case Time.parseTimeM True Time.defaultTimeLocale timestampFormat (T.unpack s) of
                Nothing -> fail "could not parse string as timestamp"
                Just time -> pure time
          _ -> fail "expected a time stamp"
        where
          timestampFormat = "%Y-%m-%dT%H:%M:%SZ"
-}

class FromInfluxPoint a where
    parseInfluxPoint :: InfluxPoint -> Parser a

instance FromInfluxPoint InfluxPoint where
    parseInfluxPoint = pure

data Cons a b = Cons { car :: a, cdr :: b }

instance (FromInfluxValue a, FromInfluxPoint b) =>
    FromInfluxPoint (Cons a b) where
    parseInfluxPoint p =
        let v = influxPointValues p
        in if V.length v >= 1
             then
                 Cons
                     <$> parseInfluxValue (V.head v)
                     <*> parseInfluxPoint (InfluxPoint (V.tail v))
             else fail "expected a non-empty vector"

instance FromInfluxPoint () where
    parseInfluxPoint _p = pure ()

instance (FromInfluxValue a, FromInfluxValue b) => FromInfluxPoint (a, b) where
    parseInfluxPoint p =
        do Cons a (Cons b ()) <- parseInfluxPoint p
           pure (a, b)

instance (FromInfluxValue a, FromInfluxValue b, FromInfluxValue c) => FromInfluxPoint (a, b, c) where
    parseInfluxPoint p =
        do Cons a (Cons b (Cons c ())) <- parseInfluxPoint p
           pure (a, b, c)

instance (FromInfluxValue a, FromInfluxValue b, FromInfluxValue c, FromInfluxValue d) => FromInfluxPoint (a, b, c, d) where
    parseInfluxPoint p =
        do Cons a (Cons b (Cons c (Cons d ()))) <- parseInfluxPoint p
           pure (a, b, c, d)

instance (FromInfluxValue a, FromInfluxValue b, FromInfluxValue c, FromInfluxValue d, FromInfluxValue e) => FromInfluxPoint (a, b, c, d, e) where
    parseInfluxPoint p =
        do Cons a (Cons b (Cons c (Cons d (Cons e ())))) <- parseInfluxPoint p
           pure (a, b, c, d, e)

instance (FromInfluxValue a, FromInfluxValue b, FromInfluxValue c, FromInfluxValue d, FromInfluxValue e, FromInfluxValue f) => FromInfluxPoint (a, b, c, d, e, f) where
    parseInfluxPoint p =
        do Cons a (Cons b (Cons c (Cons d (Cons e (Cons f ()))))) <- parseInfluxPoint p
           pure (a, b, c, d, e, f)

instance (FromInfluxValue a, FromInfluxValue b, FromInfluxValue c, FromInfluxValue d, FromInfluxValue e, FromInfluxValue f, FromInfluxValue g) => FromInfluxPoint (a, b, c, d, e, f, g) where
    parseInfluxPoint p =
        do Cons a (Cons b (Cons c (Cons d (Cons e (Cons f (Cons g ())))))) <- parseInfluxPoint p
           pure (a, b, c, d, e, f, g)

instance (FromInfluxValue a, FromInfluxValue b, FromInfluxValue c, FromInfluxValue d, FromInfluxValue e, FromInfluxValue f, FromInfluxValue g, FromInfluxValue h) => FromInfluxPoint (a, b, c, d, e, f, g, h) where
    parseInfluxPoint p =
        do Cons a (Cons b (Cons c (Cons d (Cons e (Cons f (Cons g (Cons h ()))))))) <- parseInfluxPoint p
           pure (a, b, c, d, e, f, g, h)

instance FromInfluxPoint (HV.HVect '[]) where
    parseInfluxPoint _ = pure HV.HNil

instance (FromInfluxValue t, FromInfluxPoint (HV.HVect ts)) =>
    FromInfluxPoint (HV.HVect (t ': ts)) where
    parseInfluxPoint p =
        do Cons x xs <- parseInfluxPoint p
           pure $ x HV.:&: xs

parseInfluxTable ::
  FromInfluxPoint t
  => InfluxTable
  -> ParsedTable t
parseInfluxTable table =
    let parseIfPossible row =
            case A.parseEither parseInfluxPoint row of
              Left _err -> Left row
              Right parsed -> Right parsed
        xs = map parseIfPossible (tableValues table)
        parsedRows = rights xs
        pointsThatCouldNotBeParsed = lefts xs
    in ParsedTable {..}

getQuery ::
    FromInfluxPoint t
    => Config
    -> Maybe DatabaseName
    -> Query
    -> IO (ParsedTable t)
getQuery config mDatabase query =
    do let opts = defaultQueryParams { qp_database = mDatabase }
       results <- getQueryRaw config opts query
       case results of
         [] -> fail "no result"
         _:_:_ -> fail "multiple results"
         [result] ->
             case resultTables result of
               Nothing -> fail "result has no points!"
               Just tables ->
                   case tables of
                     [] -> fail "no tables"
                     _:_:_ -> fail "multiple tables"
                     [table] -> pure (parseInfluxTable table)

serializeValue :: Value -> Maybe Text
serializeValue v =
    case v of
      Number n -> Just $ T.pack $ show n
      Integer i -> Just $ T.pack (show i) <> "i"
      String s -> Just $ T.pack $ show s
      Bool b ->
        Just $ if b then "true" else "false"
      Null -> Nothing

serializeInfluxData :: InfluxData -> Text
serializeInfluxData d =
    T.intercalate "," (escape (dataMeasurement d) : map serializeTag (dataTags d)) <> " " <>
    T.intercalate "," (mapMaybe serializeField (dataFields d)) <>
    maybe "" (\t -> " " <> serializeTimeStamp t) (dataTimestamp d)
    where
      serializeTag (k, v) =
          escape k <> "=" <> escape v
      serializeField (k, v) =
          ((escape k <> "=") <>) <$> serializeValue v
      serializeTimeStamp t = T.pack $ show $ unTimeStamp t
      escape = T.replace "," "\\," . T.replace " " "\\ "

writeParamsToQueryString :: WriteParams -> [(B.ByteString, Maybe B.ByteString)]
writeParamsToQueryString opts =
    fmap (second Just) $
    catMaybes
    [ (,) "precision" . epochToBytestring <$> wp_precision opts
    , (,) "rp" . T.encodeUtf8 <$> wp_retentionPolicy opts
    ]

write :: Config -> DatabaseName -> WriteParams -> [InfluxData] -> IO ()
write config database opts ds =
    do let url = configServer config `urlAppend` "/write"
           queryString =
             [ ("db", Just (T.encodeUtf8 database)) ] ++
             maybe [] credsToQueryString (configCreds config) ++
             writeParamsToQueryString opts
           reqBody =
             RequestBodyBS $ T.encodeUtf8 $ T.unlines $
             map serializeInfluxData ds
       baseReq <- parseUrl url
       let req =
             setRequestMethod "POST" $
             setQueryString queryString $
             maybe id setRequestManager (configManager config) $
             setRequestBody reqBody baseReq
       void $ httpLBS req