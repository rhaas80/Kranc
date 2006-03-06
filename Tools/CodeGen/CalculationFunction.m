
(* $Id$ *)

(*  Copyright 2004 Sascha Husa, Ian Hinder, Christiane Lechner

    This file is part of Kranc.

    Kranc is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    Kranc is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Foobar; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
*)

BeginPackage["sym`"];

{GridFunctions, Shorthands, Equations, t, DeclarationIncludes,
LoopPreIncludes, GroupImplementations, PartialDerivatives, Dplus1,
Dplus2, Dplus3, Boundary, Interior, Where, AddToStencilWidth}

{INV, SQR, CUB, QAD, dot, pow, exp} 

EndPackage[];

BeginPackage["CalculationFunction`", {"CodeGen`", "sym`", "MapLookup`", "KrancGroups`", 
  "Differencing`", "Errors`", "Helpers`"}];

(* This is the only externally callable function *)
CreateCalculationFunction::usage = "";
calculationUsedGroups::usage = "";

UncommentSourceSync::usage = "UncommentSourceSync[source_struct] uncomments calls to CCTK_SyncGroup.";
GrepSyncGroups::usage = "GrepSyncGroups[source_struct] 'greps' a list of groups to be SYNC'ed from" <>
                        "code produced by CreateCalculationFunction."

VerifyCalculation::usage = "";
allVariables::usage = "";

Begin["`Private`"];

(* -------------------------------------------------------------------------- 
   General Utility Functions
   -------------------------------------------------------------------------- *)


(* remove the 'rhs' at the end of a symbol or string *)
removeRHS[x_] := Module[{string = ToString[x]},
      
      If[StringMatchQ[string, "*rhs"],
           ToExpression@StringDrop[string, -3],
           x ]
      ];

(* collect and simplify terms *)
simpCollect[collectList_, eqrhs_, localvar_, debug_] :=
  Module[{rhs, collectCoeff, all, localCollectList},
      InfoMessage[Full, localvar];

      rhs = eqrhs;

      rhs = rhs /. Abs[MathTensor`Detg] -> MathTensor`Detg;
      InfoMessage[Full, "ByteCount[rhs]: ", ByteCount@rhs];

      localCollectList = collectList /. VAR :> removeRHS@localvar;

      collectCoeff = Collect[rhs, localCollectList];
      InfoMessage[Full, "ByteCount[terms collected]: ", ByteCount@collectCoeff];

      all = Collect[rhs, localCollectList, Simplify];
      InfoMessage[Full, "ByteCount[simplified rhs]: ", ByteCount@all];

      all
      ];


(* Take a grid function name and return a name suitable for use in a local
   computation *)
localName[x_] := ToExpression[ToString[x] <> "L"];

(* Given a map (i.e. a list of rules { a -> A, b -> B, ... } return the
   inverse map { A -> a, B -> b, ...} *) 
invertMap[m_] := Map[#[[2]] -> #[[1]] &, m];

(* A convenient list of the derivative symbols *)
derivativeHeads = {D1, D2, D3, 
                          D11,
                          D21, D22,
                          D31, D32, D33, Dplus1, Dplus2, Dplus3};

(* Take an expression containing derivatives (i.e. D1[<stuff> etc) and
   "hide" all the derivatives and their contents by replacing them
   with unique new symbols.  So D1[g11] would become $NEWSYMBOL1 or
   something.  Return a list whose first element is the replaced
   expression and whose second element is a map (list of rules) which
   can be used to return the symbols to the derivatives *)
hideDerivatives[x_] :=
  Module[{derivatives, unhide, hide},
    derivatives = Union[Cases[x, _ ? (MemberQ[derivativeHeads, #] &)[__],Infinity]];
    unhide = Map[Unique[] -> # &, derivatives];
    hide = invertMap[unhide];

    {x /. hide, unhide}];

(* Apply the map (list of rules) to the expression x, but avoid replacing
   anything in a derivative (D1[<stuff>]) by first "hiding" the derivatives. *)
replaceWithDerivativesHidden[x_, map_] :=
  Module[{hide = hideDerivatives[x], newExpr, unhide},
    newExpr = hide[[1]]; (* The expression with the derivatives hidden *)
    unhide = hide[[2]]; (* The map to unhide the derivatives *)
    (newExpr /. map) /. unhide];

(* Change D21[g11] into D21[g11,i,j,k] (for example)*)
replaceDerivatives[x_, derivRules_] :=
  Module[{},
    replaceStandard = (d_ ? (MemberQ[derivativeHeads, #] &)[f_] -> d[f,Symbol["i"],Symbol["j"],Symbol["k"]]);
    replaceCustom = Flatten[derivRules,1];
    x /. replaceStandard];

(* Return a CodeGen block which assigns dest by evaluating expr *)
assignVariableFromExpression[dest_, expr_] := Module[{tSym, cleanExpr, code},
      
      tSym = Unique[];
      
      cleanExpr = ReplacePowers[expr] /. sym`t -> tSym;
  
      If[SOURCELANGUAGE == "C",      
        code = ToString[dest == cleanExpr, CForm,       PageWidth -> 120] <> ";\n",
        code = ToString@dest <> ".eq." <> ToString[cleanExpr, FortranForm, PageWidth -> 120] <> "\n"
       ];
 
      If[SOURCELANGUAGE != "C",
         Module[{},
           code = StringReplace[code, "\n  "      -> " &\n"];
           code = StringReplace[code, "   -  "    -> " &  "];
           code = StringReplace[code, ".eq."      -> " = "];
           code = StringReplace[code, "=        " -> "="];
           code = StringReplace[code, "\\"        -> ""];
           code = StringReplace[code, "(index)"   -> "(i,j,k)"];
         ];
      ];

      code = StringReplace[code, "=="          -> " = "];
      code = StringReplace[code, "BesselJ"-> "gsl_sf_bessel_Jn"];
      code = StringReplace[code, ToString@tSym -> "cctk_time"];
      code = StringReplace[code, "\"" -> ""];

      {code}];

(* This flag determines whether you want to generate debugging code to
   do CCTK_INFO on the variables as they are translated.  This can
   help find problems in the construction of the translator maps. *)

debugInLoop = False;


declareVariablesForCalculation[calc_] :=
  Module[{shorthands, localGFs},
    shorthands = Sort@Union@Map[ToString, Union@Flatten@calculationAllUsedShorthands@calc];
    shorthands = PartitionVarList@shorthands;

    localGFs = Map[localName, Sort@Union@Map[ToString, Union@Flatten@calculationUsedGFs@calc]];
    localGFs = PartitionVarList@localGFs;

    {CommentedBlock["Declare shorthands",
       Map[DeclareVariables[#, "CCTK_REAL"] &, shorthands]],

     CommentedBlock["Declare local copies of grid functions",
       Map[DeclareVariables[#, "CCTK_REAL"] &, localGFs]]}];

(* Derivative precomputation *)

oldDerivativesUsed[x_] :=
  Union[Cases[x, _ ? (MemberQ[derivativeHeads, #] &)[_],Infinity]];

(* Expects a list of the form {D11[h22], ...} *)
declarePrecomputedDerivatives[derivs_] :=
  Module[{vars},
    vars = PartitionVarList@Map[ToString[Head[#]] <> ToString[First[#]] &, derivs];
    {Map[DeclareVariables[#, "CCTK_REAL"] &, vars], "\n\n"}];

precomputeDerivative[d_] :=
  Module[{h=ToString[Head[d]], f = ToString[First[d]]},
  {h <> f, " = ", h, "gf(", f, ",i,j,k)" <> EOL[] <>"\n"}];

printEq[eq_] := 
  Module[{lhs, rhs, rhsSplit, split, rhsString},

    lhs = First@eq;
    rhs = Last@eq;

    split[ x_ + y___] := { x, " + ..."};
    split[-x_ + y___] := {-x, " + ..."};
    split[ x_       ] := { x, ""};

    rhsSplit = split[Expand@ReplacePowers@rhs];

    rhsString = ToString@CForm[rhsSplit[[1]]] <> rhsSplit[[2]];

    InfoMessage[Full, " " <> ToString@lhs <> " -> " <> rhsString]];

(* Return the names of any gridfunctions used in the calculation *)
calculationUsedGFs[calc_] :=
  Module[{calcSymbols, allGFs},
    calcSymbols = calculationSymbols[calc];
    allGFs = allVariables[lookup[calc, Groups]];
    Intersection[calcSymbols, allGFs]];

calculationUsedGFsLHS[calc_] :=
  Module[{calcSymbols, allGFs},
    calcSymbols = calculationSymbolsLHS[calc];
    allGFs = allVariables[lookup[calc, Groups]];
    Intersection[calcSymbols, allGFs]];


calculationUsedGFsRHS[calc_] :=
  Module[{calcSymbols, allGFs},
    calcSymbols = calculationSymbolsRHS[calc];
    allGFs = allVariables[lookup[calc, Groups]];
    Intersection[calcSymbols, allGFs]];


calculationUsedGroups[calc_] :=
  Module[{gfs},
    gfs = calculationUsedGFs[calc];
    containingGroups[gfs, lookup[calc, Groups]]];

(* Return the names of any shorthands used in the RHSs of calculation *)
calculationRHSUsedShorthands[calc_] :=
  Module[{calcSymbols, allShorthands},
    calcSymbols = calculationSymbolsRHS[calc];
    allShorthands = lookupDefault[calc, Shorthands, {}];
    Intersection[calcSymbols, allShorthands]];

(* Return the names of any shorthands used in the LHSs of calculation *)
calculationLHSUsedShorthands[calc_] :=
  Module[{calcSymbols, allShorthands},
    calcSymbols = calculationSymbolsLHS[calc];
    allShorthands = lookupDefault[calc, Shorthands, {}];
    Intersection[calcSymbols, allShorthands]];

(* Return the names of any shorthands used anywhere in a calculation *)
calculationAllUsedShorthands[calc_] :=
  Module[{calcSymbols, allShorthands},
    calcSymbols = calculationSymbols[calc];
    allShorthands = lookupDefault[calc, Shorthands, {}];
    Intersection[calcSymbols, allShorthands]];

calculationSymbols[calc_] :=
  Module[{allAtoms},
    allAtoms = Union[Level[lookup[calc, Equations], {-1}],  Level[Map[Last, lookup[calc,PartialDerivatives]], {-1}]];
    Cases[allAtoms, x_Symbol]];

calculationSymbolsLHS[calc_] :=
  Module[{allAtoms},
    allAtoms = Union[Map[First, Flatten@lookup[calc, Equations] ]];
    Cases[allAtoms, x_Symbol]];

calculationSymbolsRHS[calc_] :=
  Module[{allAtoms},
    allAtoms = Union[Map[Last, Flatten@{lookup[calc, Equations], lookup[calc,PartialDerivatives]} ]];
    allAtoms = Union[Level[allAtoms, {-1}]];
    Cases[allAtoms, x_Symbol]];

(* Return all the functions used in a calculation *)
functionsInCalculation[calc_] :=
  Module[{eqs, x},
    eqs = lookup[calc, Equations];
    x = Cases[eqs, f_[x___] -> f, Infinity];
    y = Union[Select[x, Context[#] === "Global`" &]];
    y];



simplifyEquationList[eqs_] :=
  Map[simplifyEquation, eqs];

simplifyEquation[lhs_ -> rhs_] :=
  lhs -> Simplify[rhs];
  
VerifyListContent[l_, type_] :=
  Module[{types},
    If[!(Head[l] === List),
      ThrowError["Expecting a list of ", type, " objects, but found ", l]];
    types = Union[Map[Head, l]];
    If [!(types === {type}) && !(types === {}),
      ThrowError["Expecting a list of ", type , " objects, but found ", l]]];

VerifyCalculation[calc_] :=
  Module[{},
    If[Head[calc] != List,
      ThrowError["Invalid Calculation structure: " <> ToString[calc]]];

    VerifyListContent[calc, Rule];

    If[mapContains[calc, Shorthands],
      VerifyListContent[lookup[calc, Shorthands], Symbol]];

    If[mapContains[calc, Equations],
      VerifyListContent[First[lookup[calc, Equations]], Rule],
      ThrowError["Invalid Calculation structure. Must contain Equations element: " <> ToString[calc]]];
  ];


(* Remove equations in the calculation which assign to shorthands
   which are never used. Do not modify the Shorthands entry. This
   routine has two shortcomings.  First, it does not get rid of as
   many shorthand assignments as it could in the case where there is
   more than one list of equations in Equations.  I do not intend to
   fix this as I consider the feature of having more than one list of
   equations to be obsolete.  The second shortcoming is that an unused
   shorthand might be missed if the order of assignments is
   pathalogical enough (e.g. {s1 -> s2, s2 -> s1} would not be
   removed). *)

removeUnusedShorthands[calc_] :=
  Module[{rhsShorthands, lhsShorthands, unusedButAssignedShorthands, removeShorts, eqs, neweqs, newCalc},
    rhsShorthands = calculationRHSUsedShorthands[calc];
    lhsShorthands = calculationLHSUsedShorthands[calc];
    unusedButAssignedShorthands = Complement[lhsShorthands, rhsShorthands];

    eqs = lookup[calc, Equations];
    removeShorts[eqlist_] :=
      Select[eqlist, (!MemberQ[unusedButAssignedShorthands, First[#]]) &];

    neweqs = Map[removeShorts, eqs];
    newCalc = mapReplace[calc, Equations, neweqs];

    If[!(eqs === neweqs),
      removeUnusedShorthands[newCalc],
      newCalc]];

syncGroup[name_] :=
 If[SOURCELANGUAGE == "C",
  {"/* SYNC: "<>name<>" */\n", "/* sync via schedule instead of CCTK_SyncGroup(cctkGH, \"", name, "\"); -cut- */\n"},
  {"/* SYNC: "<>name<>" */\n", "/* sync via schedule instead of call CCTK_SyncGroup(i, cctkGH, \"", name, "\") -cut- */\n"}
  ];


UncommentSourceSync[setRHS_]:= Module[{cleanRHS},
   cleanRHS = Map[SafeStringReplace[#, "/* sync via schedule instead of ", ""]&, setRHS, Infinity];
   cleanRHS = Map[SafeStringReplace[#, ") -cut- */", ")"]&,  cleanRHS, Infinity]; (* for Fortran *)
   cleanRHS = Map[SafeStringReplace[#, "); -cut- */", ");"]&, cleanRHS, Infinity]; (* for C       *)

   cleanRHS
];

InsertSyncFuncName[setRHS_, funcName_]:=
     Map[SafeStringReplace[#, "/* SYNC: ", "/* SYNC: " <> funcName <> "//"]&, setRHS, Infinity];

GrepSyncGroups[setRHS_]:= Module[{grepSYNC},
 grepSYNC = Map[PickMatch[#, "*SYNC*"] &, Flatten[setRHS, Infinity]];
 grepSYNC = Select[grepSYNC, IsNotEmptyString];

 grepSYNC = Map[StringReplace[#, "/* SYNC: " -> ""]&, grepSYNC];
 grepSYNC = Map[StringReplace[#, "*/"        -> ""]&, grepSYNC];

 grepSYNC
];

GrepSyncGroups[x_, func_] := Module[{pick},

    pick = GrepSyncGroups[x];
    pick = Map[PickMatch[#, func <> "//*"] & , pick];
    pick = Select[pick, IsNotEmptyString];
    
    pick = Map[StringReplace[#,  func <> "//" -> ""] &, pick]
    ]

(* Calculation function generation *)

CreateCalculationFunction[calc_, debug_] :=
  Module[{gfs, allSymbols, knownSymbols,
          shorts, eqs, syncGroups, parameters,
          functionName, dsUsed, groups, pddefs, cleancalc, numeq, eqLoop, GrepSYNC, where, addToStencilWidth},

  cleancalc = removeUnusedShorthands[calc];
  shorts = lookupDefault[cleancalc, Shorthands, {}];
  eqs    = lookup[cleancalc, Equations];
  syncGroups = lookupDefault[cleancalc, SyncGroups, {}];
  parameters = lookupDefault[cleancalc, Parameters, {}];
  groups = lookup[cleancalc, Groups];
  pddefs = lookupDefault[cleancalc, PartialDerivatives, {}];
  where = lookupDefault[cleancalc, Where, Everywhere];
  addToStencilWidth = lookupDefault[cleancalc, AddToStencilWidth, 0];

  numeq = Length@eqs;

  InfoMessage[Full, "number of equations in calculation: ", numeq];

  VerifyCalculation[cleancalc];

  gfs = allVariables[groups];
  functionName = ToString@lookup[cleancalc, Name];
  dsUsed = oldDerivativesUsed[eqs];

  InfoMessage[Terse, "Creating calculation function: " <> functionName];

  InfoMessage[Full, " ", Length@shorts, " shorthands"];
  InfoMessage[Full, " ", Length@gfs, " grid functions"];
  InfoMessage[Full, " ", Length@groups, " groups"];

  InfoMessage[Full, "Shorthands: ", shorts];
  InfoMessage[Full, "Grid functions: ", gfs];
  InfoMessage[Full, "Groups: ", Map[groupName, groups]];

   If[Length@lookupDefault[cleancalc, CollectList, {}] > 0,

     eqs = Table[Map[First[#] -> simpCollect[lookup[cleancalc, CollectList], 
                                             Last[ #], 
                                             First[#], debug]&, 
                 eqs[[i]] ], {i, 1, Length@eqs}]
   ];

  InfoMessage[Full, "Equations:"];

  Map[Map[printEq, #]&, eqs];

  (* Check all the function names *)

  functionsPresent = functionsInCalculation[cleancalc];

(* FIXME: Sascha does not understand the next lines and commented
  it out in order to avod problems with using the exp function in BSSN  *)
(*   allowedFunctions = Map[Head[First[#]] &, pddefs]; *)
(*  Print["allowedFunctions == ", allowedFunctions];*)

(*  unknownFunctions = Complement[functionsPresent, allowedFunctions];

  If[Length[unknownFunctions] != 0,
     ThrowError["The following functions are used in the calculation but are not defined:", 
                unknownFunctions, cleancalc]];

*)
  (* Check that there are no shorthands defined with the same name as a grid function *)
  If[!(Intersection[shorts, gfs] === {}),
    ThrowError["The following shorthands are already declared as grid functions:", Intersection[shorts, gfs]]];

  (* Check that there are no unknown symbols in the calculation *)
  allSymbols = calculationSymbols[cleancalc];
  knownSymbols = Join[gfs, shorts, parameters, {t, Pi, E, Symbol["i"], Symbol["j"], Symbol["k"]}];

  unknownSymbols = Complement[allSymbols, knownSymbols];

  If[unknownSymbols != {},
     Module[{},
       ThrowError["Unknown symbols in calculation.  Symbols are:", unknownSymbols, "Calculation is:", cleancalc]]];

  DefineCCTKSubroutine[lookup[cleancalc, Name],
  { DeclareGridLoopVariables[],
    DeclareFDVariables[],
    declareVariablesForCalculation[cleancalc],
    declarePrecomputedDerivatives[dsUsed],
    DeclareDerivatives[pddefs, eqs],

    CommentedBlock["Include user-supplied include files",
      Map[IncludeFile, lookupDefault[cleancalc, DeclarationIncludes, {}]]],

    InitialiseFDVariables[],

    If[gfs != {},
      {
      (* This has been moved into equationLoop, in order           *)
      (* to be able to discriminate between the offsets necessary  *)
      (* depending on whether or not we take derivatives           *)

       (* InitialiseGridLoopVariables[], *)


       (* Have removed ability to include external header files here.
          Can be put back when we need it. *)

	eqLoop = Map[equationLoop[#, gfs, shorts, {}, groups, syncGroups, pddefs, where, addToStencilWidth] &, eqs]};

       (* search for SYNCs *)
       If[numeq <= 1,
         GrepSYNC = GrepSyncGroups[eqLoop],
         GrepSYNC = {};
         eqLoop = UncommentSourceSync[eqLoop];
         InfoMessage[Warning, "> 1 loop in thorn -> scheduling in source code, incompatible with Multipatch!"];
       ];

       InfoMessage[Full, "grepSync from eqLoop: ",GrepSyncGroups[eqLoop]];

       InsertSyncFuncName[eqLoop, lookup[cleancalc, Name]],
      {}]}]];


allVariables[groups_] :=
  Flatten[Map[variablesInGroup, groups], 1];

variablesInGroup[g_] :=
  g[[2]];

groupName[g_] :=
  g[[1]];

(* Check that the given list of equations assigns things in the
   correct order.  Specifically, shorthands must not be used before
   they are assigned.  *)

checkEquationAssignmentOrder[eqs_, shorthands_] :=
  Module[{},
    Map[checkShorthandAssignmentOrder[eqs,#] &, shorthands]];

equationUsesShorthand[eq_, shorthand_] :=
    Length[Cases[{Last[eq]}, shorthand, Infinity]] != 0;

checkShorthandAssignmentOrder[eqs_, shorthand_] :=
  Module[{useBooleans, uses, firstUse, lhss, assignments},

  (* Make a list of booleans describing, for each equation, whether it
     uses the given shorthand *)
  useBooleans = Map[equationUsesShorthand[#, shorthand] &, eqs];

  uses = Position[useBooleans, True];

  lhss = Map[First, eqs];

  (* The equation numbers that define this shorthand *)
  assignments = Position[lhss, shorthand];

  If[Length[uses] == 0 && Length[assignments] >= 1, 
    InfoMessage[Warning, "WARNING: Shorthand ", shorthand, " is defined but not used in this equation list."]];

  If[Length[uses] == 0, Return[]];

  (* The number of the first equation to use this shorthand *)
  firstUse = First[uses];

  If[Length[assignments] > 1,
     InfoMessage[Warning, "WARNING: Shorthand ", shorthand, " is defined more than once."]];

  If[Length[assignments] == 0,
    ThrowError["Shorthand", shorthand, "is not defined in this equation list", eqs]];

  If[assignments[[1]] >= firstUse,
    ThrowError["Shorthand", shorthand, "is used before it is defined in this equation list", eqs]]];

defContainsShorthand[def_, shorthands_] :=
Module[{allAtoms, c},
  allAtoms = Union[Level[def, {-1}]];
  c = Intersection[shorthands, allAtoms];
  c != {}];


(* Split the list of partial derivative definitions into those
containing shorthands, and those that do not.  *)

splitPDDefsWithShorthands[pddefs_, shorthands_] :=
  Module[{defsWithShorts, defsWithoutShorts},
    defsWithShorts = Select[pddefs, defContainsShorthand[#, shorthands] &];
    defsWithoutShorts = Select[pddefs, ! defContainsShorthand[#, shorthands] &];
    Return[{defsWithoutShorts, defsWithShorts}]];





equationLoop[eqs_, gfs_, shorts_, incs_, groups_, syncGroups_, pddefs_, where_, addToStencilWidth_] :=
  Module[{rhss, lhss, gfsInRHS, gfsInLHS, localGFs, localMap, eqs2,
          derivSwitch, actualSyncGroups, code, syncCode, loopFunction},

    rhss = Map[#[[2]] &, eqs];
    lhss = Map[#[[1]] &, eqs];

    gfsInRHS = Union[Cases[rhss, _ ? (MemberQ[gfs,#] &), Infinity]];
    gfsInLHS = Union[Cases[lhss, _ ? (MemberQ[gfs,#] &), Infinity]];

    localGFs = Map[localName, gfs];
    localMap = Map[# -> localName[#] &, gfs];
    
    derivSwitch = Join[oldDerivativesUsed[eqs], GridFunctionDerivativesInExpression[pddefs, eqs]] != {};

    (* Replace the partial derivatives *)

    {defsWithoutShorts, defsWithShorts} = splitPDDefsWithShorthands[pddefs, shorts];


    (* This is for the custom derivative operators pddefs *)
    eqs2 = ReplaceDerivatives[defsWithoutShorts, eqs, True];
    eqs2 = ReplaceDerivatives[defsWithShorts, eqs2, False];

    checkEquationAssignmentOrder[eqs2, shorts];
   code = {InitialiseGridLoopVariables[derivSwitch, addToStencilWidth],

   loopFunction = Switch[where,
    Boundary, BoundaryLoop,
    _, GridLoop];

   loopFunction[
   {CommentedBlock["Assign local copies of grid functions",
                   Map[AssignVariable[localName[#], GridName[#]] &, 
                       gfsInRHS]],

    CommentedBlock["Include user supplied include files",
                   Map[IncludeFile, incs]],

    CommentedBlock["Precompute derivatives (new style)",
                   PrecomputeDerivatives[defsWithoutShorts, eqs]],

    CommentedBlock["Precompute derivatives (old style)",
                   Map[precomputeDerivative, oldDerivativesUsed[eqs]]],

    CommentedBlock["Calculate temporaries and grid functions",
                   Map[{assignVariableFromExpression[#[[1]], #[[2]]], "\n"}  &,
                   replaceDerivatives[
                     replaceWithDerivativesHidden[eqs2, localMap],{}]]],

    If[debugInLoop, Map[InfoVariable[#[[1]]] &, eqs2 /. localMap], ""], 

    CommentedBlock["Copy local copies back to grid functions",
                   Map[AssignVariable[GridName[#], localName[#]] &, 
                       gfsInLHS]],

    If[debugInLoop, Map[InfoVariable[GridName[#]] &, gfsInLHS], ""]}]
   };

  lhsGroupNames    = containingGroups[gfsInLHS, groups];
  actualSyncGroups = Intersection[lhsGroupNames, syncGroups];

    (* This is nonsense.  You need to synchronize only if the NEXT
    loops contain derivatives.  This cannot be determined here, so I am
    changing the code  so that synchronization is always performed *)

(*  If[Not@derivSwitch, actualSyncGroups = {}];  only sync when derivs are taken *)

  If[Length@actualSyncGroups > 0,
    InfoMessage[Full, "Synchronizing groups: ", actualSyncGroups];
     syncCode = Map[syncGroup, actualSyncGroups];

    AppendTo[code, CommentedBlock["Synchronize the groups that have just been set", syncCode]];
];

code
];


End[];

EndPackage[];
