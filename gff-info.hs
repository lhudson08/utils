#!/usr/bin/env runghc

{-# LANGUAGE DeriveDataTypeable,TupleSections #-}

import Control.Monad
import Control.Applicative
import Data.Maybe
import Data.List
import Data.List.Split
import qualified Data.Map as M
import Debug.Trace
import Text.Printf
import Text.Regex.PCRE
import Control.Monad.State
import System.Console.CmdArgs hiding (typ)

data Options = Options { stats :: Bool
                       , overlapping_cds :: Bool
                       , update_ids :: Maybe FilePath
                       , feature_prefix :: String
                       , files :: [FilePath]
                       } deriving (Show,Eq,Data,Typeable)

options :: Options
options = Options
          { stats = True &= help "Output some stats about the GFF and its features"
          , overlapping_cds = False &= help "Check if there are any overlapping CDS features"
          , update_ids = Nothing &= help "Rename all feature IDs in the GFF"
          , feature_prefix = "FID_" &= help "Prefix to use when renaming all feature IDs"
          , files = [] &= args &= typFile
          }


data GFF = GFF { scaffolds :: [Scaffold]
               , features :: [Feature]
               }

data Scaffold = Scaffold { s_name :: String, dna :: String }
              deriving (Show)

data Feature = Feature { seq_id, source, typ :: String
                       , start, end :: Int
                       , score, strand, phase :: String
                       , attributes :: M.Map String [String]
                       } deriving (Show)

lineToFeature :: String -> Feature
lineToFeature l = Feature {seq_id = cols!!0, source = cols!!1, typ = cols!!2
                          ,start = read (cols!!3), end = read (cols!!4)
                          ,score = cols!!5, strand = cols!!6, phase = cols!!7
                          ,attributes = attribToMap (cols!!8)
                          }
  where
    cols = splitOn "\t" l
    attribToMap s = M.fromListWith (++) $ mapMaybe toPair $ splitOn ";" s
    toPair s = case splitOn "=" s of
                 [k,v] -> Just (k,[v])
                 [""] -> Nothing
                 x -> error $ "Bad attribute pair : "++show x++" : "++show s

featureToLine :: Feature -> String
featureToLine f = intercalate "\t" $ map ($f) [seq_id, source, typ, show.start, show.end, score, strand, phase
                                              ,mapToAttrib . attributes]
    where
      mapToAttrib mp = intercalate ";" $ map (\(k,vs) -> concatMap (\v -> k++"="++v) vs) $ M.toList mp

featId :: Feature -> String
featId f = featAttrib "ID" f

featAttrib :: String -> Feature -> String
featAttrib k f = maybe "" head $ M.lookup k $ attributes f

setFeatAttrib :: String -> Feature -> String -> Feature
setFeatAttrib k f v = f { attributes = M.insert k [v] (attributes f) }

parseScaffold :: [String] -> (Scaffold, [String])
parseScaffold (l:ls) = let name = tail (dropWhile (' ' /=) l)
                           (dnaLines,rest) = break ("##end-DNA" `isPrefixOf`) ls
                       in (Scaffold {s_name = name, dna = concatMap (drop 2) dnaLines}
                          , rest)

parseLines :: [String] -> GFF
parseLines [] = GFF [] []
parseLines lss@(l:ls)
    | "##DNA " `isPrefixOf` l = let (s,rem) = parseScaffold lss in addScaffold s (parseLines rem)
    | "##" `isPrefixOf` l     = parseLines ls
    | otherwise               = addFeature (lineToFeature l) (parseLines ls)
  where
    addFeature f gff = gff { features  = f : features gff }
    addScaffold s gff = gff { scaffolds = s : scaffolds gff }

getScaffold :: GFF -> String -> Maybe Scaffold
getScaffold gff name = lookup name $ map (\s -> (s_name s, s)) (scaffolds gff)

featSeq :: GFF -> Feature -> String
featSeq gff f = case getScaffold gff (seq_id f) of
                  Nothing -> error "No scaffold by the name : "++seq_id f
                  Just sc -> take (featLen f) . drop (start f - 1) . dna $ sc

-- | TODO, should check ##gff-version
parseGff :: [String] -> GFF
parseGff ls = parseLines ls

gffOutput :: GFF -> [String]
gffOutput gff = ["##gff-version 3"]
                ++ map (\s -> printf "##Type DNA %s" (s_name s)) (scaffolds gff)
                ++ concatMap scaffoldOutput (scaffolds gff)
                ++ map featureToLine (features gff)
  where
    scaffoldOutput s = [printf "##DNA %s" (s_name s)]
                       ++ map ("##"++) (toChunks 40 $ dna s)
                       ++ ["##end-DNA"]

toChunks _ [] = []
toChunks n s = let (a,b) = splitAt n s
               in a : toChunks n b



featSel :: String -> [Feature] -> [Feature]
featSel f = filter ((f==).typ)

overlap f1 f2 = let ov = overlapR (start f1,end f1) (start f2, end f2)
                    res = ov && strand f1 == strand f2
                in if res then trace (show f1 ++ show f2) res else res
  where
    overlapR (a,b) (c,d) =  (a>=c && a<=d)
                         || (b>=c && b<=d)
                         || (a<=c && b>=d)

anyOverlap [] = False
anyOverlap (l:ls) = any (overlap l) ls || anyOverlap ls

featLen :: Feature -> Int
featLen f = end f - start f

avg :: (Integral a, Integral b) => a -> b -> Double
avg a b = fromIntegral a / fromIntegral b

overlappingCDS gff = do
  let cds = featSel "CDS" (features gff)
  let byContig = grpBy seq_id cds
  -- mapM_ (putStrLn . head . head)  byContig
  mapM_ (\c -> putStrLn (seq_id (head c)) >> print (anyOverlap c) )  byContig


prStats :: GFF -> IO ()
prStats gff = do
  let genes = featSel "gene" (features gff)
  printf "Num Genes = %d\n" (length genes)

  -- CDS info
  let cds = featSel "CDS" (features gff)
  printf "Avg CDS per gene = %.1f\n" (avg (length cds) (length genes))

  let joinedCDS = grpBy featId cds
  let totCDS = sum $ map (\cs -> sum $ map featLen cs) joinedCDS
  let avgCDS = avg totCDS (length joinedCDS)
  printf "Avg joined CDS length = %.1f (%.1faa)\n" avgCDS (avgCDS / 3)

  printf "Coding = %.1f%%\n" (100 * avg totCDS (sum . map (length . dna) . scaffolds $ gff))

  -- Tot info
  putStrLn "Total : "
  putStr "  " >> prSummary (map (length . dna) . scaffolds $ gff)
  putStr "  " >> prSeqStats (concatMap dna . scaffolds $ gff)

  printf "Num scaffolds = %s\n" (formatInt . length . scaffolds $ gff)

  putStrLn ""

  -- Per feature info
  forM_ (allTypes gff) $ \t ->
      putStrLn (t++ " : ") >> prFeatStats gff (featSel t (features gff))

  return ()

allTypes :: GFF -> [String]
allTypes gff = nub . map typ . features $ gff

prFeatStats :: GFF -> [Feature] -> IO ()
prFeatStats gff fs = do
  let featLens = map featLen fs
  putStr "  " >> prSummary featLens
  putStr "  " >> prSeqStats (concatMap (featSeq gff) fs)

prSummary :: [Int] -> IO ()
prSummary nums =
  printf "Num=%s avg=%.1fbp min=%sbp max=%sbp\n" (formatInt $ length nums)
             (avg (sum nums) (length nums)) (formatInt $ minimum nums) (formatInt $ maximum nums)

prSeqStats :: String -> IO ()
prSeqStats dna = do
  let counts = M.assocs $ M.fromListWith (+) $ map (,1) dna
  -- print counts
  let tot = sum $ map snd counts
  let [a,t,g,c,n] = map (\c -> fromMaybe (0::Int) . lookup c $ counts) "ATGCN"
  printf "Total=%sbp Ns=%d G+C=%.1f%%\n" (formatInt tot) n (100 * avg (g+c) (a+t+g+c))

-- | Renumber all features that already have an ID.
setFeatureIDs :: String -> GFF -> GFF
setFeatureIDs pre gff =
    let (fs,state) = runState (mapM (updateFeatId "ID" nextId) $ features gff) (1, M.empty)
        fs' = evalState (mapM (updateFeatId "Parent" missingId) fs) state
    in gff { features = fs' }
  where
    missingId id = error $ "ID missing : "++show id

    nextId :: String -> State (Int, M.Map String String) String
    nextId id = do (int, mp) <- get
                   let id' = pre ++ printf "%05d" int++"0"
                   put (int+1, M.insert id id' mp)
                   return id'

    updateFeatId :: String -> (String -> State (Int, M.Map String String) String) -> Feature
                 -> State (Int, M.Map String String) Feature
    updateFeatId fld no_id f = do (int, mp) <- get
                                  case featAttrib fld f of
                                    "" -> return f
                                    v -> case M.lookup v mp of
                                           Just v' -> return $ setFeatAttrib fld f v'
                                           Nothing -> do v' <- no_id v
                                                         return $ setFeatAttrib fld f v'

grpBy :: Ord k => (a -> k) -> [a] -> [[a]]
grpBy f ls = grpBy' (Just . f) ls

grpBy' :: Ord k => (a -> Maybe k) -> [a] -> [[a]]
grpBy' f ls = M.elems . M.fromListWith (++) . mapMaybe (\l -> f l >>= \k -> return (k,[l])) $ ls

formatInt :: Show a => a -> String
formatInt x = h++t
    where
        sp = break (== '.') $ show x
        h = reverse (intercalate "," $ chunksOf 3 $ reverse $ fst sp)
        t = snd sp


stdinOrFiles :: Options -> IO String
stdinOrFiles opts | null (files opts) = putStrLn "Reading from stdin..." >> getContents
                  | otherwise = concat <$> mapM readFile (files opts)

main = do
  opts <- cmdArgs options
  ls <- lines <$> stdinOrFiles opts

  let gff = parseGff ls
  -- print . featSeq gff . head . features $ gff

  when (stats opts) $ prStats gff
  when (overlapping_cds opts) $ overlappingCDS gff

  case update_ids opts of
    Nothing -> return ()
    Just outFile -> do putStrLn $ "Writing to file : "++outFile
                       writeFile outFile . unlines . gffOutput . setFeatureIDs (feature_prefix opts) $ gff