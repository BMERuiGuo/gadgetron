#pragma once

#include "Gadget.h"
#include "../core/GadgetMRIHeaders.h"


#include <boost/python.hpp>
#include <boost/python/tuple.hpp>
#include "gadgetronpython_export.h"
#include "ismrmrd.h"
namespace Gadgetron{
class EXPORTGADGETSPYTHON GadgetReference
{

 public:
  GadgetReference();
  ~GadgetReference();
  
  int set_gadget(Gadget* g)
  {
    gadget_ = g;
    return 0;
  }

  template<class T> int return_data(T header, boost::python::object arr);
  int return_acquisition(ISMRMRD::AcquisitionHeader acq, boost::python::object arr);
  int return_image(ISMRMRD::ImageHeader img, boost::python::object arr);

 protected:
  Gadget* gadget_;

};
}
