{-
Copyright (C) 2010 John MacFarlane <jgm@berkeley.edu>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
-}

{- |
   Module      : Text.Pandoc.Writers.EPUB
   Copyright   : Copyright (C) 2010 John MacFarlane
   License     : GNU GPL, version 2 or above

   Maintainer  : John MacFarlane <jgm@berkeley.edu>
   Stability   : alpha
   Portability : portable

Conversion of 'Pandoc' documents to EPUB.
-}
module Text.Pandoc.Writers.EPUB ( writeEPUB ) where
import Data.IORef
import Data.Maybe ( fromMaybe, isNothing )
import Data.List ( isPrefixOf, intercalate )
import System.Environment ( getEnv )
import Text.Printf (printf)
import System.FilePath ( (</>), (<.>), takeBaseName, takeExtension, takeFileName )
import qualified Data.ByteString.Lazy as B
import Text.Pandoc.UTF8 ( fromStringLazy )
import Codec.Archive.Zip
import Data.Time.Clock.POSIX
import Text.Pandoc.Shared hiding ( Element )
import qualified Text.Pandoc.Shared as Shared
import Text.Pandoc.Options
import Text.Pandoc.Definition
import Text.Pandoc.Generic
import Text.Pandoc.Templates
import Control.Monad.State
import Text.XML.Light hiding (ppTopElement)
import Text.Pandoc.UUID
import Text.Pandoc.Writers.HTML
import Text.Pandoc.Writers.Markdown ( writePlain )
import Data.Char ( toLower )
import Network.URI ( unEscapeString )
import Text.Pandoc.MIME (getMimeType)
import Prelude hiding (catch)
import Control.Exception (catch, SomeException)
import Text.HTML.TagSoup

-- | Produce an EPUB file from a Pandoc document.
writeEPUB :: WriterOptions  -- ^ Writer options
          -> Pandoc         -- ^ Document to convert
          -> IO B.ByteString
writeEPUB opts doc@(Pandoc meta _) = do
  epochtime <- floor `fmap` getPOSIXTime
  let mkEntry path content = toEntry path epochtime content
  let opts' = opts{ writerEmailObfuscation = NoObfuscation
                  , writerStandalone = True
                  , writerWrapText = False }
  let sourceDir = writerSourceDirectory opts'
  let vars = writerVariables opts'
  let mbCoverImage = lookup "epub-cover-image" vars

  titlePageTemplate <- readDataFile (writerUserDataDir opts)
                       $ "templates" </> "epub-titlepage" <.> "html"

  coverImageTemplate <- readDataFile (writerUserDataDir opts)
                       $ "templates" </> "epub-coverimage" <.> "html"

  pageTemplate <- readDataFile (writerUserDataDir opts)
                       $ "templates" </> "epub-page" <.> "html"

  -- cover page
  (cpgEntry, cpicEntry) <-
                case mbCoverImage of
                     Nothing   -> return ([],[])
                     Just img  -> do
                       let coverImage = "cover-image" ++ takeExtension img
                       let cpContent = fromStringLazy $ writeHtmlString
                             opts'{writerTemplate = coverImageTemplate,
                                   writerVariables = ("coverimage",coverImage):vars}
                               (Pandoc meta [])
                       imgContent <- B.readFile img
                       return ( [mkEntry "cover.xhtml" cpContent]
                              , [mkEntry coverImage imgContent] )

  -- title page
  let tpContent = fromStringLazy $ writeHtmlString
                     opts'{writerTemplate = titlePageTemplate}
                     (Pandoc meta [])
  let tpEntry = mkEntry "title_page.xhtml" tpContent

  -- handle pictures
  picsRef <- newIORef []
  Pandoc _ blocks <- bottomUpM
       (transformInlines (writerHTMLMathMethod opts) sourceDir picsRef) doc
  pics <- readIORef picsRef
  let readPicEntry (oldsrc, newsrc) = readEntry [] oldsrc >>= \e ->
                                          return e{ eRelativePath = newsrc }
  picEntries <- mapM readPicEntry pics

  -- handle fonts
  let mkFontEntry f = mkEntry (takeFileName f) `fmap` B.readFile f
  fontEntries <- mapM mkFontEntry $ writerEpubFonts opts

  -- body pages
  -- add level 1 header to beginning if none there
  let blocks' = case blocks of
                      (Header 1 _ _ : _) -> blocks
                      _                  -> Header 1 nullAttr (docTitle meta) : blocks
  -- internal reference IDs change when we chunk the file,
  -- so the next two lines fix that:
  let reftable = correlateRefs blocks'
  let blocks'' = replaceRefs reftable blocks'
  let tags = parseTags $ writeHtmlString opts'{writerStandalone = False}
                       $ Pandoc (Meta [] [] []) blocks''

  let chunks = partitions (~== TagOpen "h1" []) tags

  let chapToEntry :: Int -> [Tag String] -> Entry
      chapToEntry num ts = mkEntry (showChapter num)
           $ fromStringLazy
           $ renderTemplate [("body",renderTags ts)]
           $ pageTemplate

  let chapterEntries = zipWith chapToEntry [1..] chunks

  -- contents.opf
  localeLang <- catch (liftM (map (\c -> if c == '_' then '-' else c) .
                       takeWhile (/='.')) $ getEnv "LANG")
                    (\e -> let _ = (e :: SomeException) in return "en-US")
  let lang = case lookup "lang" (writerVariables opts') of
                     Just x  -> x
                     Nothing -> localeLang
  uuid <- getRandomUUID
  let chapterNode ent = unode "item" !
                           [("id", takeBaseName $ eRelativePath ent),
                            ("href", eRelativePath ent),
                            ("media-type", "application/xhtml+xml")] $ ()
  let chapterRefNode ent = unode "itemref" !
                             [("idref", takeBaseName $ eRelativePath ent)] $ ()
  let pictureNode ent = unode "item" !
                           [("id", takeBaseName $ eRelativePath ent),
                            ("href", eRelativePath ent),
                            ("media-type", fromMaybe "application/octet-stream"
                               $ imageTypeOf $ eRelativePath ent)] $ ()
  let fontNode ent = unode "item" !
                           [("id", takeBaseName $ eRelativePath ent),
                            ("href", eRelativePath ent),
                            ("media-type", maybe "" id $ getMimeType $ eRelativePath ent)] $ ()
  let plainify t = trimr $
                    writePlain opts'{ writerStandalone = False } $
                    Pandoc meta [Plain t]
  let plainTitle = plainify $ docTitle meta
  let plainAuthors = map plainify $ docAuthors meta
  let plainDate = maybe "" id $ normalizeDate $ stringify $ docDate meta
  let contentsData = fromStringLazy $ ppTopElement $
        unode "package" ! [("version","2.0")
                          ,("xmlns","http://www.idpf.org/2007/opf")
                          ,("unique-identifier","BookId")] $
          [ metadataElement (writerEPUBMetadata opts')
              uuid lang plainTitle plainAuthors plainDate mbCoverImage
          , unode "manifest" $
             [ unode "item" ! [("id","ncx"), ("href","toc.ncx")
                              ,("media-type","application/x-dtbncx+xml")] $ ()
             , unode "item" ! [("id","style"), ("href","stylesheet.css")
                              ,("media-type","text/css")] $ ()
             ] ++
             map chapterNode (cpgEntry ++ (tpEntry : chapterEntries)) ++
             map pictureNode (cpicEntry ++ picEntries) ++
             map fontNode fontEntries
          , unode "spine" ! [("toc","ncx")] $
              case mbCoverImage of
                    Nothing -> []
                    Just _ -> [ unode "itemref" !
                                [("idref", "cover"),("linear","no")] $ () ]
              ++ map chapterRefNode (tpEntry : chapterEntries)
          ]
  let contentsEntry = mkEntry "content.opf" contentsData

  -- toc.ncx
  let secs = hierarchicalize blocks''

  let navPointNode :: Shared.Element -> State Int Element
      navPointNode (Sec _ nums ident ils children) = do
        n <- get
        modify (+1)
        let showNums :: [Int] -> String
            showNums = intercalate "." . map show
        let tit' = plainify ils
        let tit = if writerNumberSections opts
                     then showNums nums ++ " " ++ tit'
                     else tit'
        let src = case lookup ident reftable of
                       Just x  -> x
                       Nothing -> error (ident ++ " not found in reftable")
        let isSec (Sec lev _ _ _ _) = lev <= 3  -- only includes levels 1-3
            isSec _                 = False
        let subsecs = filter isSec children
        subs <- mapM navPointNode subsecs
        return $ unode "navPoint" !
               [("id", "navPoint-" ++ show n)
               ,("playOrder", show n)] $
                  [ unode "navLabel" $ unode "text" tit
                  , unode "content" ! [("src", src)] $ ()
                  ] ++ subs
      navPointNode (Blk _) = error "navPointNode encountered Blk"

  let tpNode = unode "navPoint" !  [("id", "navPoint-0")] $
                  [ unode "navLabel" $ unode "text" (plainify $ docTitle meta)
                  , unode "content" ! [("src","title_page.xhtml")] $ () ]

  let tocData = fromStringLazy $ ppTopElement $
        unode "ncx" ! [("version","2005-1")
                       ,("xmlns","http://www.daisy.org/z3986/2005/ncx/")] $
          [ unode "head" $
             [ unode "meta" ! [("name","dtb:uid")
                              ,("content", show uuid)] $ ()
             , unode "meta" ! [("name","dtb:depth")
                              ,("content", "1")] $ ()
             , unode "meta" ! [("name","dtb:totalPageCount")
                              ,("content", "0")] $ ()
             , unode "meta" ! [("name","dtb:maxPageNumber")
                              ,("content", "0")] $ ()
             ] ++ case mbCoverImage of
                        Nothing  -> []
                        Just _   -> [unode "meta" ! [("name","cover"),
                                            ("content","cover-image")] $ ()]
          , unode "docTitle" $ unode "text" $ plainTitle
          , unode "navMap" $ tpNode : evalState (mapM navPointNode secs) 1
          ]
  let tocEntry = mkEntry "toc.ncx" tocData

  -- mimetype
  let mimetypeEntry = mkEntry "mimetype" $ fromStringLazy "application/epub+zip"

  -- container.xml
  let containerData = fromStringLazy $ ppTopElement $
       unode "container" ! [("version","1.0")
              ,("xmlns","urn:oasis:names:tc:opendocument:xmlns:container")] $
         unode "rootfiles" $
           unode "rootfile" ! [("full-path","content.opf")
               ,("media-type","application/oebps-package+xml")] $ ()
  let containerEntry = mkEntry "META-INF/container.xml" containerData

  -- com.apple.ibooks.display-options.xml
  let apple = fromStringLazy $ ppTopElement $
        unode "display_options" $
          unode "platform" ! [("name","*")] $
            unode "option" ! [("name","specified-fonts")] $ "true"
  let appleEntry = mkEntry "META-INF/com.apple.ibooks.display-options.xml" apple

  -- stylesheet
  stylesheet <- case writerEpubStylesheet opts of
                   Just s  -> return s
                   Nothing -> readDataFile (writerUserDataDir opts) "epub.css"
  let stylesheetEntry = mkEntry "stylesheet.css" $ fromStringLazy stylesheet

  -- construct archive
  let archive = foldr addEntryToArchive emptyArchive
                 (mimetypeEntry : containerEntry : appleEntry : stylesheetEntry : tpEntry :
                  contentsEntry : tocEntry :
                  (picEntries ++ cpicEntry ++ cpgEntry ++ chapterEntries ++ fontEntries) )
  return $ fromArchive archive

metadataElement :: String -> UUID -> String -> String -> [String] -> String -> Maybe a -> Element
metadataElement metadataXML uuid lang title authors date mbCoverImage =
  let userNodes = parseXML metadataXML
      elt = unode "metadata" ! [("xmlns:dc","http://purl.org/dc/elements/1.1/")
                               ,("xmlns:opf","http://www.idpf.org/2007/opf")] $
            filter isMetadataElement $ onlyElems userNodes
      dublinElements = ["contributor","coverage","creator","date",
            "description","format","identifier","language","publisher",
            "relation","rights","source","subject","title","type"]
      isMetadataElement e = (qPrefix (elName e) == Just "dc" &&
                             qName (elName e) `elem` dublinElements) ||
                            (qPrefix (elName e) == Nothing &&
                             qName (elName e) `elem` ["link","meta"])
      contains e n = not (null (findElements (QName n Nothing (Just "dc")) e))
      newNodes = [ unode "dc:title" title | not (elt `contains` "title") ] ++
           [ unode "dc:language" lang | not (elt `contains` "language") ] ++
           [ unode "dc:identifier" ! [("id","BookId")] $ show uuid |
               not (elt `contains` "identifier") ] ++
           [ unode "dc:creator" ! [("opf:role","aut")] $ a | a <- authors ] ++
           [ unode "dc:date" date | not (elt `contains` "date") ] ++
           [ unode "meta" ! [("name","cover"), ("content","cover-image")] $ () |
               not (isNothing mbCoverImage) ]
  in  elt{ elContent = elContent elt ++ map Elem newNodes }

transformInlines :: HTMLMathMethod
                 -> FilePath
                 -> IORef [(FilePath, FilePath)] -- ^ (oldpath, newpath) images
                 -> [Inline]
                 -> IO [Inline]
transformInlines _ _ _ (Image lab (src,_) : xs) | isNothing (imageTypeOf src) =
  return $ Emph lab : xs
transformInlines _ sourceDir picsRef (Image lab (src,tit) : xs) = do
  let src' = unEscapeString src
  pics <- readIORef picsRef
  let oldsrc = sourceDir </> src'
  let ext = takeExtension src'
  newsrc <- case lookup oldsrc pics of
                  Just n  -> return n
                  Nothing -> do
                        let new = "images/img" ++ show (length pics) ++ ext
                        modifyIORef picsRef ( (oldsrc, new): )
                        return new
  return $ Image lab (newsrc, tit) : xs
transformInlines (MathML _) _ _ (x@(Math _ _) : xs) = do
  let writeHtmlInline opts z = trimr $
         writeHtmlString opts $ Pandoc (Meta [] [] []) [Plain [z]]
      mathml = writeHtmlInline def{writerHTMLMathMethod = MathML Nothing } x
      fallback = writeHtmlInline def{writerHTMLMathMethod = PlainMath } x
      inOps = "<ops:switch xmlns:ops=\"http://www.idpf.org/2007/ops\">" ++
       "<ops:case required-namespace=\"http://www.w3.org/1998/Math/MathML\">" ++
       mathml ++ "</ops:case><ops:default>" ++ fallback ++ "</ops:default>" ++
       "</ops:switch>"
      result = if "<math" `isPrefixOf` mathml then inOps else mathml
  return $ RawInline "html" result : xs
transformInlines _ _ _ xs = return xs

(!) :: Node t => (t -> Element) -> [(String, String)] -> t -> Element
(!) f attrs n = add_attrs (map (\(k,v) -> Attr (unqual k) v) attrs) (f n)

-- | Version of 'ppTopElement' that specifies UTF-8 encoding.
ppTopElement :: Element -> String
ppTopElement = ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++) . unEntity . ppElement
  -- unEntity removes numeric  entities introduced by ppElement
  -- (kindlegen seems to choke on these).
  where unEntity [] = ""
        unEntity ('&':'#':xs) =
                   let (ds,ys) = break (==';') xs
                       rest = drop 1 ys
                   in  case safeRead ('\'':'\\':ds ++ "'") of
                          Just x   -> x : unEntity rest
                          Nothing  -> '&':'#':unEntity xs
        unEntity (x:xs) = x : unEntity xs

imageTypeOf :: FilePath -> Maybe String
imageTypeOf x = case drop 1 (map toLower (takeExtension x)) of
                     "jpg"       -> Just "image/jpeg"
                     "jpeg"      -> Just "image/jpeg"
                     "jfif"      -> Just "image/jpeg"
                     "png"       -> Just "image/png"
                     "gif"       -> Just "image/gif"
                     "svg"       -> Just "image/svg+xml"
                     _           -> Nothing


data IdentState = IdentState{
       chapterNumber :: Int,
       runningIdents :: [String],
       chapterIdents :: [String],
       identTable    :: [(String,String)]
       } deriving (Read, Show)

-- Returns filename for chapter number.
showChapter :: Int -> String
showChapter = printf "ch%03d.xhtml"

-- Go through a block list and construct a table
-- correlating the automatically constructed references
-- that would be used in a normal pandoc document with
-- new URLs to be used in the EPUB.  For example, what
-- was "header-1" might turn into "ch006.xhtml#header".
correlateRefs :: [Block] -> [(String,String)]
correlateRefs bs = identTable $ execState (mapM_ go bs)
                                IdentState{ chapterNumber = 0
                                          , runningIdents = []
                                          , chapterIdents = []
                                          , identTable = [] }
 where go :: Block -> State IdentState ()
       go (Header n attr ils) = do
          when (n == 1) $
              modify $ \s -> s{ chapterNumber = chapterNumber s + 1
                              , chapterIdents = [] }
          st <- get
          let runningid = uniqueIdent ils (runningIdents st)
          let chapid    = if n == 1
                             then Nothing
                             else Just $ uniqueIdent ils (chapterIdents st)
          modify $ \s -> s{ runningIdents = runningid : runningIdents st
                          , chapterIdents = maybe (chapterIdents st)
                                              (: chapterIdents st) chapid
                          , identTable = (runningid,
                              showChapter (chapterNumber st) ++
                              maybe "" ('#':) chapid) : identTable st
                           }
       go _ = return ()

-- Replace internal link references using the table produced
-- by correlateRefs.
replaceRefs :: [(String,String)] -> [Block] -> [Block]
replaceRefs refTable = bottomUp replaceOneRef
  where replaceOneRef x@(Link lab ('#':xs,tit)) =
          case lookup xs refTable of
                Just url -> Link lab (url,tit)
                Nothing  -> x
        replaceOneRef x = x
