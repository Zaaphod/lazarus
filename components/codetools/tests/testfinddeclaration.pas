{
 Test with:
   ./testcodetools --suite=TTestFindDeclaration
   ./testcodetools --suite=TestFindDeclaration_Basic
   ./testcodetools --suite=TestFindDeclaration_ClassOf
   ./testcodetools --suite=TestFindDeclaration_With
   ./testcodetools --suite=TestFindDeclaration_NestedClasses
   ./testcodetools --suite=TestFindDeclaration_ClassHelper
   ./testcodetools --suite=TestFindDeclaration_TypeHelper
   ./testcodetools --suite=TestFindDeclaration_ObjCClass
   ./testcodetools --suite=TestFindDeclaration_ObjCCategory
   ./testcodetools --suite=TestFindDeclaration_Generics
   ./testcodetools --suite=TestFindDeclaration_FileAtCursor

 FPC tests:
   ./testcodetools --suite=TestFindDeclaration_FPCTests
   ./testcodetools --suite=TestFindDeclaration_FPCTests --filemask=t*.pp
   ./testcodetools --suite=TestFindDeclaration_FPCTests --filemask=tchlp41.pp
 Laz tests:
   ./testcodetools --suite=TestFindDeclaration_LazTests
   ./testcodetools --suite=TestFindDeclaration_LazTests --filemask=t*.pp
   ./testcodetools --suite=TestFindDeclaration_LazTests --filemask=tdefaultproperty1.pp
}
unit TestFindDeclaration;

{$mode objfpc}{$H+}

{off $define VerboseFindDeclarationTests}

interface

uses
  Classes, SysUtils, contnrs,
  fpcunit, testregistry,
  FileProcs, LazFileUtils, LazLogger,
  CodeToolManager, ExprEval, CodeCache, BasicCodeTools,
  CustomCodeTool, CodeTree, FindDeclarationTool, KeywordFuncLists,
  IdentCompletionTool, TestPascalParser;

const
  MarkDecl = '#'; // a declaration, must be unique
  MarkRef = '@'; // a reference to a declaration

type
  TFDMarker = class
  public
    Name: string;
    Kind: char;
    CleanPos: integer;
    NameStartPos, NameEndPos: integer;
  end;

  { TCustomTestFindDeclaration }

  TCustomTestFindDeclaration = class(TCustomTestPascalParser)
  private
    FMainCode: TCodeBuffer;
    FMarkers: TObjectList;// list of TFDMarker
    FMainTool: TCodeTool;
    function GetMarkers(Index: integer): TFDMarker;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
    function MarkerCount: integer;
    property Markers[Index: integer]: TFDMarker read GetMarkers;
    function AddMarker(const aName: string; Kind: char; CleanPos: integer;
      NameStartPos, NameEndPos: integer): TFDMarker;
    function IndexOfMarker(const aName: string; Kind: char): integer;
    function FindMarker(const aName: string; Kind: char): TFDMarker;
    procedure CheckReferenceMarkers;
    procedure FindDeclarations(Filename: string);
    procedure TestFiles(Directory: string);
    procedure WriteSource(CleanPos: integer; Tool: TCodeTool = nil);
    procedure WriteSource(const CursorPos: TCodeXYPosition);
    property MainCode: TCodeBuffer read FMainCode;
    property MainTool: TCodeTool read FMainTool;
  end;

  { TTestFindDeclaration }

  TTestFindDeclaration = class(TCustomTestFindDeclaration)
  published
    procedure TestFindDeclaration_Basic;
    procedure TestFindDeclaration_Proc_BaseTypes;
    procedure TestFindDeclaration_With;
    procedure TestFindDeclaration_ClassOf;
    procedure TestFindDeclaration_NestedClasses;
    procedure TestFindDeclaration_ClassHelper;
    procedure TestFindDeclaration_TypeHelper;
    procedure TestFindDeclaration_ObjCClass;
    procedure TestFindDeclaration_ObjCCategory;
    procedure TestFindDeclaration_Generics;
    procedure TestFindDeclaration_ForIn;
    procedure TestFindDeclaration_FileAtCursor;
    procedure TestFindDeclaration_CBlocks;
    procedure TestFindDeclaration_Arrays;
    procedure TestFindDeclaration_GuessType;
    // test all files in directories:
    procedure TestFindDeclaration_FPCTests;
    procedure TestFindDeclaration_LazTests;
  end;

implementation

{ TCustomTestFindDeclaration }

procedure TCustomTestFindDeclaration.CheckReferenceMarkers;
var
  i, FoundTopLine, FoundCleanPos, BlockTopLine, BlockBottomLine: Integer;
  Marker, DeclMarker: TFDMarker;
  CursorPos, FoundCursorPos: TCodeXYPosition;
  FoundTool: TFindDeclarationTool;
begin
  for i:=0 to MarkerCount-1 do begin
    Marker:=Markers[i];
    if Marker.Kind=MarkRef then begin
      DeclMarker:=FindMarker(Marker.Name,MarkDecl);
      if DeclMarker=nil then
        Fail('ref has no decl marker. ref "'+Marker.Name+'" at '+MainTool.CleanPosToStr(Marker.CleanPos));
      MainTool.CleanPosToCaret(Marker.NameStartPos,CursorPos);

      // test FindDeclaration
      if not CodeToolBoss.FindDeclaration(CursorPos.Code,CursorPos.X,CursorPos.Y,
        FoundCursorPos.Code,FoundCursorPos.X,FoundCursorPos.Y,FoundTopLine,
        BlockTopLine,BlockBottomLine)
      then begin
        WriteSource(CursorPos);
        Fail('find declaration failed at '+MainTool.CleanPosToStr(Marker.NameStartPos,true)+': '+CodeToolBoss.ErrorMessage);
      end else begin
        FoundTool:=CodeToolBoss.GetCodeToolForSource(FoundCursorPos.Code,true,true) as TFindDeclarationTool;
        if FoundTool<>MainTool then begin
          WriteSource(CursorPos);
          Fail('find declaration at '+MainTool.CleanPosToStr(Marker.NameStartPos,true)
            +' returned wrong tool "'+FoundTool.MainFilename+'" instead of "'+MainTool.MainFilename+'"');
        end;
        MainTool.CaretToCleanPos(FoundCursorPos,FoundCleanPos);
        if (FoundCleanPos<DeclMarker.NameStartPos)
        or (FoundCleanPos>DeclMarker.NameEndPos) then begin
          WriteSource(CursorPos);
          Fail('find declaration at '+MainTool.CleanPosToStr(Marker.NameStartPos,true)
            +' returned wrong position "'+MainTool.CleanPosToStr(FoundCleanPos)+'"'
            +' instead of "'+MainTool.CleanPosToStr(Marker.NameStartPos)+'"');
        end;
      end;
    end;
  end;
end;

procedure TCustomTestFindDeclaration.FindDeclarations(Filename: string);

  procedure PrependPath(Prefix: string; var Path: string);
  begin
    if Path<>'' then Path:='.'+Path;
    Path:=Prefix+Path;
  end;

  function NodeAsPath(Tool: TFindDeclarationTool; Node: TCodeTreeNode): string;
  begin
    Result:='';
    while Node<>nil do begin
      case Node.Desc of
      ctnTypeDefinition,ctnVarDefinition,ctnConstDefinition,ctnGenericParameter:
        PrependPath(GetIdentifier(@Tool.Src[Node.StartPos]),Result);
      ctnGenericType:
        PrependPath(GetIdentifier(@Tool.Src[Node.FirstChild.StartPos]),Result);
      ctnInterface,ctnUnit:
        PrependPath(Tool.GetSourceName(false),Result);
      ctnProcedure:
        PrependPath(Tool.ExtractProcName(Node,[]),Result);
      ctnProperty:
        PrependPath(Tool.ExtractPropName(Node,false),Result);
      ctnUseUnitNamespace,ctnUseUnitClearName:
        begin
          PrependPath(GetIdentifier(@Tool.Src[Node.StartPos]),Result);
          if Node.PriorBrother<>nil then begin
            Node:=Node.PriorBrother;
            continue;
          end;
        end;
      //else debugln(['NodeAsPath ',Node.DescAsString]);
      end;
      Node:=Node.Parent;
    end;
    //debugln(['NodeAsPath ',Result]);
  end;

var
  CommentP: Integer;
  p: Integer;
  ExpectedPath: String;
  PathPos: Integer;
  CursorPos, FoundCursorPos: TCodeXYPosition;
  FoundTopLine: integer;
  FoundTool: TFindDeclarationTool;
  FoundCleanPos: Integer;
  FoundNode: TCodeTreeNode;
  FoundPath: String;
  Src: String;
  NameStartPos, i, l, IdentifierStartPos, IdentifierEndPos,
    BlockTopLine, BlockBottomLine: Integer;
  Marker, ExpectedType, NewType: String;
  IdentItem: TIdentifierListItem;
  ItsAKeyword, IsSubIdentifier: boolean;
  ExistingDefinition: TFindContext;
  ListOfPFindContext: TFPList;
  NewExprType: TExpressionType;
begin
  Filename:=TrimAndExpandFilename(Filename);
  {$IFDEF VerboseFindDeclarationTests}
  debugln(['TTestFindDeclaration.FindDeclarations File=',Filename]);
  {$ENDIF}
  FMainCode:=CodeToolBoss.LoadFile(Filename,true,false);
  if MainCode=nil then
    raise Exception.Create('unable to load '+Filename);
  if not CodeToolBoss.Explore(MainCode,FMainTool,true) then begin
    AssertEquals('parse error '+CodeToolBoss.ErrorMessage,false,true);
    exit;
  end;
  CommentP:=1;
  Src:=MainTool.Src;
  while CommentP<length(Src) do begin
    CommentP:=FindNextComment(Src,CommentP);
    if CommentP>length(Src) then break;
    p:=CommentP;
    CommentP:=FindCommentEnd(Src,CommentP,MainTool.Scanner.NestedComments);
    if Src[p]<>'{' then continue;
    if Src[p+1] in ['$','%',' ',#0..#31] then continue;

    IdentifierStartPos:=p;
    IdentifierEndPos:=p;
    while (IdentifierStartPos>1) and (IsIdentChar[Src[IdentifierStartPos-1]]) do
      dec(IdentifierStartPos);
    if IdentifierStartPos=p then begin
      WriteSource(p);
      Fail('missing identifier in front of marker at '+MainTool.CleanPosToStr(p));
    end;
    inc(p);
    NameStartPos:=p;
    if Src[p] in ['#','@'] then begin
      inc(p);
      if not IsIdentStartChar[Src[p]] then begin
        WriteSource(p);
        Fail('Expected identifier at '+MainTool.CleanPosToStr(p,true));
      end;
      NameStartPos:=p;
      while IsIdentChar[Src[p]] do inc(p);
      Marker:=copy(Src,NameStartPos,p-NameStartPos);
      AddMarker(Marker,Src[NameStartPos],CommentP,IdentifierStartPos,IdentifierEndPos);
      continue;
    end;

    if not IsIdentStartChar[Src[p]] then continue;
    while (p<=length(Src)) and (IsIdentChar[Src[p]]) do inc(p);
    Marker:=copy(Src,NameStartPos,p-NameStartPos);
    if (p>length(Src)) or (Src[p]<>':') then begin
      WriteSource(p);
      AssertEquals('Expected : at '+MainTool.CleanPosToStr(p,true),'declaration',Marker);
      continue;
    end;
    inc(p);
    PathPos:=p;

    //debugln(['TTestFindDeclaration.FindDeclarations Marker="',Marker,'" params: ',dbgstr(MainTool.Src,p,CommentP-p)]);
    if (Marker='declaration') then begin
      ExpectedPath:=copy(Src,PathPos,CommentP-1-PathPos);
      {$IFDEF VerboseFindDeclarationTests}
      debugln(['TTestFindDeclaration.FindDeclarations searching "',Marker,'" at ',Tool.CleanPosToStr(NameStartPos-1),' ExpectedPath=',ExpectedPath]);
      {$ENDIF}
      MainTool.CleanPosToCaret(IdentifierStartPos,CursorPos);

      // test FindDeclaration
      if not CodeToolBoss.FindDeclaration(CursorPos.Code,CursorPos.X,CursorPos.Y,
        FoundCursorPos.Code,FoundCursorPos.X,FoundCursorPos.Y,FoundTopLine,
        BlockTopLine,BlockBottomLine)
      then begin
        if ExpectedPath<>'' then begin
          WriteSource(IdentifierStartPos);
          Fail('find declaration failed at '+MainTool.CleanPosToStr(IdentifierStartPos,true)+': '+CodeToolBoss.ErrorMessage);
        end;
        continue;
      end else begin
        FoundTool:=CodeToolBoss.GetCodeToolForSource(FoundCursorPos.Code,true,true) as TFindDeclarationTool;
        FoundPath:='';
        if (FoundCursorPos.Y=1) and (FoundCursorPos.X=1) then begin
          // unit
          FoundPath:=ExtractFileNameOnly(FoundCursorPos.Code.Filename);
        end else begin
          FoundTool.CaretToCleanPos(FoundCursorPos,FoundCleanPos);
          FoundNode:=FoundTool.FindDeepestNodeAtPos(FoundCleanPos,true);
          //debugln(['TTestFindDeclaration.FindDeclarations Found: ',FoundTool.CleanPosToStr(FoundNode.StartPos,true)]);
          FoundPath:=NodeAsPath(FoundTool,FoundNode);
        end;
        //debugln(['TTestFindDeclaration.FindDeclarations FoundPath=',FoundPath]);
        if LowerCase(ExpectedPath)<>LowerCase(FoundPath) then begin
          WriteSource(IdentifierStartPos);
          AssertEquals('find declaration wrong at '+MainTool.CleanPosToStr(IdentifierStartPos,true),LowerCase(ExpectedPath),LowerCase(FoundPath));
        end;
      end;

      // test identifier completion
      if (ExpectedPath<>'') then begin
        if not CodeToolBoss.GatherIdentifiers(CursorPos.Code,CursorPos.X,CursorPos.Y)
        then begin
          if ExpectedPath<>'' then begin
            WriteSource(IdentifierStartPos);
            AssertEquals('GatherIdentifiers failed at '+MainTool.CleanPosToStr(IdentifierStartPos,true)+': '+CodeToolBoss.ErrorMessage,false,true);
          end;
          continue;
        end else begin
          i:=CodeToolBoss.IdentifierList.GetFilteredCount-1;
          while i>=0 do begin
            IdentItem:=CodeToolBoss.IdentifierList.FilteredItems[i];
            //debugln(['TTestFindDeclaration.FindDeclarations ',IdentItem.Identifier]);
            l:=length(IdentItem.Identifier);
            if ((l=length(ExpectedPath)) or (ExpectedPath[length(ExpectedPath)-l]='.'))
            and (CompareText(IdentItem.Identifier,RightStr(ExpectedPath,l))=0)
            then break;
            dec(i);
          end;
          if i<0 then begin
            WriteSource(IdentifierStartPos);
            AssertEquals('GatherIdentifiers misses "'+ExpectedPath+'" at '+MainTool.CleanPosToStr(IdentifierStartPos,true),true,i>=0);
          end;
        end;
      end;
    end else if Marker='guesstype' then begin
      ExpectedType:=copy(Src,PathPos,CommentP-1-PathPos);
      {$IFDEF VerboseFindDeclarationTests}
      debugln(['TTestFindDeclaration.FindDeclarations "',Marker,'" at ',Tool.CleanPosToStr(NameStartPos-1),' ExpectedType=',ExpectedType]);
      {$ENDIF}
      MainTool.CleanPosToCaret(IdentifierStartPos,CursorPos);

      // test GuessTypeOfIdentifier
      ListOfPFindContext:=nil;
      try
        if not CodeToolBoss.GuessTypeOfIdentifier(CursorPos.Code,CursorPos.X,CursorPos.Y,
          ItsAKeyword, IsSubIdentifier, ExistingDefinition, ListOfPFindContext,
          NewExprType, NewType)
        then begin
          if ExpectedType<>'' then
            AssertEquals('GuessTypeOfIdentifier failed at '+MainTool.CleanPosToStr(IdentifierStartPos,true)+': '+CodeToolBoss.ErrorMessage,false,true);
          continue;
        end else begin
          //debugln(['TTestFindDeclaration.FindDeclarations FoundPath=',FoundPath]);
          if LowerCase(ExpectedType)<>LowerCase(NewType) then begin
            WriteSource(IdentifierStartPos);
            AssertEquals('GuessTypeOfIdentifier wrong at '+MainTool.CleanPosToStr(IdentifierStartPos,true),LowerCase(ExpectedType),LowerCase(NewType));
          end;
        end;
      finally
        FreeListOfPFindContext(ListOfPFindContext);
      end;

    end else begin
      WriteSource(IdentifierStartPos);
      AssertEquals('Unknown marker at '+MainTool.CleanPosToStr(IdentifierStartPos,true),'declaration',Marker);
      continue;
    end;
  end;
  CheckReferenceMarkers;
end;

function TCustomTestFindDeclaration.GetMarkers(Index: integer): TFDMarker;
begin
  Result:=TFDMarker(FMarkers[Index]);
end;

procedure TCustomTestFindDeclaration.TestFiles(Directory: string);
const
  fmparam = '--filemask=';
var
  Info: TSearchRec;
  aFilename, Param, aFileMask: String;
  i: Integer;
  Verbose: Boolean;
begin
  aFileMask:='t*.p*';
  Verbose:=false;
  for i:=1 to ParamCount do begin
    Param:=ParamStr(i);
    if LeftStr(Param,length(fmparam))=fmparam then
      aFileMask:=copy(Param,length(fmparam)+1,100);
    if Param='-v' then
      Verbose:=true;
  end;
  Directory:=AppendPathDelim(Directory);

  if FindFirstUTF8(Directory+aFileMask,faAnyFile,Info)=0 then begin
    repeat
      if faDirectory and Info.Attr>0 then continue;
      aFilename:=Info.Name;
      if not FilenameIsPascalUnit(aFilename) then continue;
      if Verbose then
        debugln(['TTestFindDeclaration.TestFiles File="',aFilename,'"']);
      FindDeclarations(Directory+aFilename);
    until FindNextUTF8(Info)<>0;
  end;
end;

procedure TCustomTestFindDeclaration.WriteSource(CleanPos: integer; Tool: TCodeTool);
var
  Caret: TCodeXYPosition;
begin
  if Tool=nil then Tool:=MainTool;
  if Tool=nil then
    Fail('TTestFindDeclaration.WriteSource: missing Tool');
  if not Tool.CleanPosToCaret(CleanPos,Caret) then
    Fail('TTestFindDeclaration.WriteSource: invalid cleanpos '+IntToStr(CleanPos)+' Tool='+Tool.MainFilename);
  WriteSource(Caret);
end;

procedure TCustomTestFindDeclaration.WriteSource(const CursorPos: TCodeXYPosition);
var
  CurCode: TCodeBuffer;
  i: Integer;
  Line: String;
begin
  CurCode:=CursorPos.Code;
  if CurCode=nil then
    Fail('TTestFindDeclaration.WriteSource CurCode=nil');
  for i:=1 to CurCode.LineCount do begin
    Line:=CurCode.GetLine(i-1,false);
    if (i=CursorPos.Y) then begin
      write('*');
      Line:=LeftStr(Line,CursorPos.X-1)+'|'+copy(Line,CursorPos.X,length(Line));
    end;
    writeln(Format('%:4d: ',[i]),Line);
  end;
end;

procedure TCustomTestFindDeclaration.SetUp;
begin
  inherited SetUp;
  FMarkers:=TObjectList.Create(true);
end;

procedure TCustomTestFindDeclaration.TearDown;
begin
  FMainCode:=nil;
  FMainTool:=nil;
  FreeAndNil(FMarkers);
  inherited TearDown;
end;

function TCustomTestFindDeclaration.MarkerCount: integer;
begin
  if FMarkers=nil then
    Result:=0
  else
    Result:=FMarkers.Count;
end;

function TCustomTestFindDeclaration.AddMarker(const aName: string; Kind: char;
  CleanPos: integer; NameStartPos, NameEndPos: integer): TFDMarker;
begin
  if (Kind=MarkDecl) then begin
    Result:=FindMarker(aName,Kind);
    if Result<>nil then
      Fail('duplicate decl marker at '+MainTool.CleanPosToStr(CleanPos)+' and at '+MainTool.CleanPosToStr(Result.CleanPos));
  end;
  Result:=TFDMarker.Create;
  Result.Name:=aName;
  Result.Kind:=Kind;
  Result.CleanPos:=CleanPos;
  Result.NameStartPos:=NameStartPos;
  Result.NameEndPos:=NameEndPos;
  FMarkers.Add(Result);
end;

function TCustomTestFindDeclaration.IndexOfMarker(const aName: string; Kind: char
  ): integer;
var
  i: Integer;
  Marker: TFDMarker;
begin
  for i:=0 to MarkerCount-1 do begin
    Marker:=Markers[i];
    if (Marker.Kind=Kind) and (CompareText(Markers[i].Name,aName)=0) then
      exit(i);
  end;
  Result:=-1;
end;

function TCustomTestFindDeclaration.FindMarker(const aName: string; Kind: char
  ): TFDMarker;
var
  i: Integer;
begin
  i:=IndexOfMarker(aName,Kind);
  if i<0 then
    Result:=nil
  else
    Result:=Markers[i];
end;

procedure TTestFindDeclaration.TestFindDeclaration_Basic;
begin
  FindDeclarations('moduletests/fdt_basic.pas');
end;

procedure TTestFindDeclaration.TestFindDeclaration_Proc_BaseTypes;
begin
  FindDeclarations('moduletests/fdt_proc_basetypes.pas');
end;

procedure TTestFindDeclaration.TestFindDeclaration_With;
begin
  FindDeclarations('moduletests/fdt_with.pas');
end;

procedure TTestFindDeclaration.TestFindDeclaration_ClassOf;
begin
  FindDeclarations('moduletests/fdt_classof.pas');
end;

procedure TTestFindDeclaration.TestFindDeclaration_NestedClasses;
begin
  FindDeclarations('moduletests/fdt_nestedclasses.pas');
end;

procedure TTestFindDeclaration.TestFindDeclaration_ClassHelper;
begin
  FindDeclarations('moduletests/fdt_classhelper.pas');
end;

procedure TTestFindDeclaration.TestFindDeclaration_TypeHelper;
begin
  FindDeclarations('moduletests/fdt_typehelper.pas');
end;

procedure TTestFindDeclaration.TestFindDeclaration_ObjCClass;
begin
  FindDeclarations('moduletests/fdt_objcclass.pas');
end;

procedure TTestFindDeclaration.TestFindDeclaration_ObjCCategory;
begin
  FindDeclarations('moduletests/fdt_objccategory.pas');
end;

procedure TTestFindDeclaration.TestFindDeclaration_Generics;
begin
  FindDeclarations('moduletests/fdt_generics.pas');
end;

procedure TTestFindDeclaration.TestFindDeclaration_ForIn;
begin
  FindDeclarations('moduletests/fdt_for_in.pas');
end;

procedure TTestFindDeclaration.TestFindDeclaration_FileAtCursor;
var
  SubUnit2Code, LFMCode: TCodeBuffer;
  Found: TFindFileAtCursorFlag;
  FoundFilename: string;
begin
  FMainCode:=CodeToolBoss.CreateFile('test1.lpr');
  MainCode.Source:='uses unit2 in ''sub/../unit2.pas'';'+LineEnding;
  SubUnit2Code:=CodeToolBoss.CreateFile('unit2.pas');
  LFMCode:=CodeToolBoss.CreateFile('test1.lfm');
  try
    // --- used unit ---
    // test cursor on 'unit2'
    if not CodeToolBoss.FindFileAtCursor(MainCode,6,1,Found,FoundFilename) then
      Fail('CodeToolBoss.FindFileAtCursor at uses unit2');
    AssertEquals('FindFileAtCursor at uses unit2 Found',ord(ffatUsedUnit),ord(Found));
    AssertEquals('FindFileAtCursor at uses unit2 FoundFilename','unit2.pas',FoundFilename);
    // test cursor on 'in'
    if not CodeToolBoss.FindFileAtCursor(MainCode,12,1,Found,FoundFilename) then
      Fail('CodeToolBoss.FindFileAtCursor at uses unit2-in');
    AssertEquals('FindFileAtCursor at uses unit2-in Found',ord(ffatUsedUnit),ord(Found));
    AssertEquals('FindFileAtCursor at uses unit2-in FoundFilename','unit2.pas',FoundFilename);
    // test cursor on in-file literal
    if not CodeToolBoss.FindFileAtCursor(MainCode,16,1,Found,FoundFilename) then
      Fail('CodeToolBoss.FindFileAtCursor at uses unit2-in-literal');
    AssertEquals('FindFileAtCursor at uses unit2-in-lit Found',ord(ffatUsedUnit),ord(Found));
    AssertEquals('FindFileAtCursor at uses unit2-in-lit FoundFilename','unit2.pas',FoundFilename);

    // --- enabled include directive ---
    // test cursor on enabled include directive of empty file
    MainCode.Source:='program test1;'+LineEnding
      +'{$i unit2.pas}'+LineEnding;
    SubUnit2Code.Source:='';
    if not CodeToolBoss.FindFileAtCursor(MainCode,1,2,Found,FoundFilename) then
      Fail('CodeToolBoss.FindFileAtCursor at enabled include directive of empty inc');
    AssertEquals('FindFileAtCursor at enabled include directive of empty Found',ord(ffatIncludeFile),ord(Found));
    AssertEquals('FindFileAtCursor at enabled include directive of empty FoundFilename','unit2.pas',FoundFilename);

    SubUnit2Code.Source:='{$define a}';
    if not CodeToolBoss.FindFileAtCursor(MainCode,1,2,Found,FoundFilename) then
      Fail('CodeToolBoss.FindFileAtCursor at enabled include directive of non-empty inc');
    AssertEquals('FindFileAtCursor at enabled include directive of non-empty Found',ord(ffatIncludeFile),ord(Found));
    AssertEquals('FindFileAtCursor at enabled include directive of non-empty FoundFilename','unit2.pas',FoundFilename);

    // --- disabled include directive ---
    // test cursor on disabled include directive
    MainCode.Source:='program test1;'+LineEnding
      +'{$ifdef disabled}'+LineEnding
      +'{$i unit2.pas}'+LineEnding
      +'{$endif}'+LineEnding;
    SubUnit2Code.Source:='';
    if not CodeToolBoss.FindFileAtCursor(MainCode,1,3,Found,FoundFilename) then
      Fail('CodeToolBoss.FindFileAtCursor at disabled include directive');
    AssertEquals('FindFileAtCursor at disabled include directive Found',ord(ffatDisabledIncludeFile),ord(Found));
    AssertEquals('FindFileAtCursor at disabled include directive FoundFilename','unit2.pas',FoundFilename);

    // --- enabled resource directive ---
    MainCode.Source:='program test1;'+LineEnding
      +'{$R test1.lfm}'+LineEnding;
    if not CodeToolBoss.FindFileAtCursor(MainCode,1,2,Found,FoundFilename) then
      Fail('CodeToolBoss.FindFileAtCursor at enabled resource directive');
    AssertEquals('FindFileAtCursor at enabled resource directive Found',ord(ffatResource),ord(Found));
    AssertEquals('FindFileAtCursor at enabled resource directive FoundFilename','test1.lfm',FoundFilename);

    MainCode.Source:='program test1;'+LineEnding
      +'{$R *.lfm}'+LineEnding;
    if not CodeToolBoss.FindFileAtCursor(MainCode,1,2,Found,FoundFilename) then
      Fail('CodeToolBoss.FindFileAtCursor at enabled resource directive');
    AssertEquals('FindFileAtCursor at enabled resource directive Found',ord(ffatResource),ord(Found));
    AssertEquals('FindFileAtCursor at enabled resource directive FoundFilename','test1.lfm',FoundFilename);

    // --- disabled resource directive ---
    MainCode.Source:='program test1;'+LineEnding
      +'{$ifdef disabled}'+LineEnding
      +'{$R test1.lfm}'+LineEnding
      +'{$endif}'+LineEnding;
    if not CodeToolBoss.FindFileAtCursor(MainCode,1,3,Found,FoundFilename) then
      Fail('CodeToolBoss.FindFileAtCursor at disabled resource directive');
    AssertEquals('FindFileAtCursor at disabled resource directive Found',ord(ffatDisabledResource),ord(Found));
    AssertEquals('FindFileAtCursor at disabled resource directive FoundFilename','test1.lfm',FoundFilename);

    // --- literal ---
    MainCode.Source:='program test1;'+LineEnding
      +'const Cfg=''unit2.pas'';'+LineEnding;
    if not CodeToolBoss.FindFileAtCursor(MainCode,11,2,Found,FoundFilename) then
      Fail('CodeToolBoss.FindFileAtCursor in literal');
    AssertEquals('FindFileAtCursor in literal Found',ord(ffatLiteral),ord(Found));
    AssertEquals('FindFileAtCursor in literal FoundFilename','unit2.pas',FoundFilename);

    // --- comment ---
    MainCode.Source:='program test1;'+LineEnding
      +'{unit2.pas}'+LineEnding;
    if not CodeToolBoss.FindFileAtCursor(MainCode,3,2,Found,FoundFilename) then
      Fail('CodeToolBoss.FindFileAtCursor in comment');
    AssertEquals('FindFileAtCursor in comment Found',ord(ffatComment),ord(Found));
    AssertEquals('FindFileAtCursor in comment FoundFilename','unit2.pas',FoundFilename);

    // --- unit name search in comment ---
    MainCode.Source:='program test1;'+LineEnding
      +'{unit2}'+LineEnding;
    if not CodeToolBoss.FindFileAtCursor(MainCode,3,2,Found,FoundFilename) then
      Fail('CodeToolBoss.FindFileAtCursor in comment');
    AssertEquals('FindFileAtCursor in comment Found',ord(ffatUnit),ord(Found));
    AssertEquals('FindFileAtCursor in comment FoundFilename','unit2.pas',FoundFilename);

    // --- unit name search in MainCode ---
    MainCode.Source:='program test1;'+LineEnding
      +'begin'+LineEnding
      +'  unit2.Test;'+LineEnding;
    if not CodeToolBoss.FindFileAtCursor(MainCode,3,3,Found,FoundFilename) then
      Fail('CodeToolBoss.FindFileAtCursor in comment');
    AssertEquals('FindFileAtCursor in comment Found',ord(ffatUnit),ord(Found));
    AssertEquals('FindFileAtCursor in comment FoundFilename','unit2.pas',FoundFilename);

  finally
    MainCode.IsDeleted:=true;
    SubUnit2Code.IsDeleted:=true;
    LFMCode.IsDeleted:=true;
  end;
end;

procedure TTestFindDeclaration.TestFindDeclaration_CBlocks;
begin
  StartProgram;
  Add([
    '{$modeswitch cblocks}',
    'type tblock = reference to procedure; cdecl;',
    'procedure test(b: tblock);',
    'begin',
    '  b;',
    'end;',
    'procedure proc;',
    'begin',
    'end;',
    'const bconst: tblock = @proc;',
    'var',
    '  b: tblock;',
    'begin',
    '  b:=@proc;',
    '  b;',
    '  test{declaration:test1.test}(@proc);',
    '  test{declaration:test1.test}(b);',
    '  bconst{declaration:test1.bconst};',
    '  test{declaration:test1.test}(bconst{declaration:test1.bconst});',
    'end.',
  '']);
  ParseModule;
end;

procedure TTestFindDeclaration.TestFindDeclaration_Arrays;
begin
  FindDeclarations('moduletests/fdt_arrays.pas');
end;

procedure TTestFindDeclaration.TestFindDeclaration_GuessType;
begin
  FindDeclarations('moduletests/fdt_guesstype1.pas');
end;

procedure TTestFindDeclaration.TestFindDeclaration_FPCTests;
begin
  TestFiles('fpctests');
end;

procedure TTestFindDeclaration.TestFindDeclaration_LazTests;
begin
  TestFiles('laztests');
end;

initialization
  RegisterTests([TTestFindDeclaration]);
end.

