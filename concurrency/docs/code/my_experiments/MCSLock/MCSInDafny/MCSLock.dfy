include "../../../Ptrs.s.dfy"
include "../../../Atomic.s.dfy"

class Node 
{
  
  var locked : bool;
  var next : Node?;
  
  constructor ( l : bool )
  {
    locked := l;
    next := null;
  }

  method setNext ( n : Node? )
  modifies this;
  {
    next := n;
  }

  method getNext () returns ( n : Node? )
  {
    n := next;
  }

  method setLocked ()
  modifies this;
  {
    locked := true;
  }

  
  method setUnlocked ()
  modifies this;
  {
    locked := false;
  }

  method getLocked () returns ( l : bool )
  {
    l := locked;
  }

}





class MCSLock 
{
  

  var tail : Node?; // TODO: add logic to make sure it is not null


  constructor ( t : Node? ) 
  {
    tail := t;
  }


  method acquire ( myNode : Node )
  modifies myNode
  // modifies pred
  decreases *
  {
    myNode.setNext(null);
    var pred : Node? := atomic_fetch_and_store(tail, myNode);
    if (pred != null) 
    {
      myNode.setLocked();
      pred.setNext(myNode); // error on this line     
      var myLockVar : bool := myNode.getLocked();
      while (myLockVar)
      decreases *
      {
        myLockVar := myNode.getLocked();
      }
    }
  }


  method release ( myNode : Node ) 
  modifies myNode
  decreases *
  {
    var myNext : Node? := myNode.getNext(); 
    if ( myNext == null) 
    {
      var ret : bool := compare_and_swap(tail, myNode, null);
      if (!ret)
      {
        var myNext : Node? := myNode.getNext();
        while (myNext != null) 
        decreases *
        {

        }
        myNode.setUnlocked();
      }
    }
    else
    {
      myNode.setUnlocked();
    }
  } 


  method atomic_fetch_and_store ( n1 : Node?, n2 : Node? ) returns ( r : Node? )
  {
    // expetation: after this routine, r = n1 and n1 = n 2
  }


  method compare_and_swap ( n1 : Node?, n2 : Node?, n3 : Node? ) returns ( r : bool )
  {
    // expetation: after this routine,  if ( n1==n2 ) { then n1=n3; return true; } else { return false; }
  }

}




method main() 
{
  print "hi\n";
  // var l1 := new Node(3);
  // var l2 := new Node.insert(4, l1);
  // var l3 := new Node.insert(5, l2);
  // assert l1.list == [3];
  // assert l2.list == [4,3];
  // assert l3.list == [5,4,3];


  var l1 := new Node(false);
  var l2 := new Node(false);
  var l3 := new Node(false);
  var l4 := new Node(false);
  var l5 := new Node(false);

  // l1.setNext(l2);
  // l2.setNext(l3);
  // l3.setNext(l3);
  // l4.setNext(l5);
  // l5.setNext(null);
  // l1.setLocked();
  // l5.setUnlocked();
  // print l1;
  // var ll : bool := l1.getLocked();
  // print ll;

  var lock : MCSLock := new MCSLock(null); 

}




